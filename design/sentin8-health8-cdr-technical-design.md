# Sentin8 Health8:CDR - Clinical Data Repository Technical Design

Last updated: 2026-09-09
Status: Target-state design (pre-implementation)
Owners: Sentin8 Platform Engineering, Health8 Product Engineering

> **References**: `sentin8-health8-technical-design.md` (master, §4.1a
> three-layer architecture),
> `sentin8-health8-fhir-technical-design.md` (FHIR facade - maps FHIR ↔ CDR),
> `sentin8-health8-openehr-technical-design.md` (openEHR facade - maps
> openEHR ↔ CDR),
> `sentin8/design/sentin8-sentin8-db-technical-design.md` (RLS context),
> `sentin8/design/sentin8-sentin8-storage-technical-design.md`,
> `sentin8/design/sentin8-architecture-principles.md` §4.3 (defense-in-depth),
> `sentin8/design/sentin8-policy-technical-design.md` (Shield authorization).

## 1. Executive Summary

Health8:CDR is the **canonical clinical data repository** - the single source
of truth for clinical data in a **model-agnostic** form. It is deliberately
**not** a FHIR store and **not** an openEHR store: it stores clinical data in
a canonical model (subjects, clinical entries, documents, versioning, and a
search index) that is a superset of the semantics both standards express.

FHIR and openEHR are **facade services** that map their native forms to/from
CDR's canonical model:

```
   FHIR client ──► Health8:FHIR ──► ┌─────────────────────┐
                                    │   Health8:CDR       │
openEHR client ─► Health8:OpenEHR ─► │  canonical clinical │
                                    │  data repository    │
                                    └─────────────────────┘
```

- **Health8:FHIR** exposes the FHIR REST API and maps FHIR resources ↔
  canonical entries (see `sentin8-health8-fhir-technical-design.md`).
- **Health8:OpenEHR** exposes the openEHR REST API + AQL and maps compositions
  ↔ canonical entries (see `sentin8-health8-openehr-technical-design.md`).

CDR owns the canonical tables and is the only service that writes them. The
facades read/write through CDR's public API (RLS-scoped) - never by direct
table access. This is the **canonical-model architecture**: one authoritative
clinical store, with standards as interchangeable projections over it.

### 1.1 Why a canonical model

FHIR and openEHR are **not isomorphic** - FHIR is single-model (flat resources
+ extensions + profiles), openEHR is dual-model (RM + archetypes/templates +
`CONTRIBUTION`/`VERSION`). A direct mapping between them is lossy. A canonical
model resolves this by defining **one** clinical vocabulary that is a
superset of both, so:

- each facade maps its standard to/from the canonical model (a well-defined,
  per-standard mapping, not a lossy cross-standard mapping);
- the two standards can be used **simultaneously** against the same clinical
  data without either being a degraded projection of the other;
- a third standard (e.g. HL7 v2, C-CDA, or a future FHIR R6) is added by
  writing one more facade, not by re-architecting the store.

The canonical model is **not** a new public standard - it is an internal
representation. The public surfaces are FHIR and openEHR (and the Interop
formats). The canonical model exists to make those surfaces consistent.

## 2. Data Model

The canonical model has five families of tables, all in schema `health8` and
all **model-agnostic** (no FHIR or openEHR concepts):

| Family | Tables | Purpose |
|---|---|---|
| Subjects | `health8.subjects` | The holder of clinical data (patient, practitioner, …). |
| Clinical entries | `health8.clinical_entries` | Atomic clinical statements (the canonical unit). |
| Documents | `health8.documents`, `health8.document_entries` | Groupings of entries (a composition/encounter). |
| Versioning | `health8.versioned_objects`, `health8.versions` | A unified version model (superset of FHIR `meta.versionId` and openEHR `CONTRIBUTION`/`VERSION`). |
| Search index | `health8.entry_index` | Typed search columns for cross-model search. |

### 2.1 `health8.subjects`

```sql
CREATE SCHEMA IF NOT EXISTS health8;

-- Subjects - the holder of clinical data (patient, practitioner, …).
CREATE TABLE health8.subjects (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    subject_type    TEXT NOT NULL,           -- 'patient' | 'practitioner' | 'organization' | ...
    identifiers     JSONB NOT NULL DEFAULT '[]',  -- [{system, value}]
    demographics    JSONB NOT NULL DEFAULT '{}',  -- name, birthDate, gender, ...
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_subjects_env ON health8.subjects (env_id);
```

### 2.2 `health8.clinical_entries`

The **clinical entry** is the canonical unit - an atomic clinical statement
(an observation, a diagnosis, a medication, a procedure, …). It captures the
common semantics both FHIR resources and openEHR `ENTRY` subtypes express:
*what* (code), *value*, *when* (effective time), *who* (subject), and
*context* (encounter, performer, device).

```sql
CREATE TABLE health8.clinical_entries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    subject_id      UUID NOT NULL REFERENCES health8.subjects(id),
    entry_type      TEXT NOT NULL,           -- 'observation' | 'condition' | 'medication' | 'procedure' | 'allergy' | 'immunization' | ...
    code            JSONB NOT NULL DEFAULT '{}',  -- {system, code, display}
    value           JSONB,                   -- quantity | code | string | range | ...
    effective_time  TIMESTAMPTZ,
    effective_period TSTZRANGE,
    status          TEXT NOT NULL DEFAULT 'final',
    context         JSONB NOT NULL DEFAULT '{}',  -- encounter, performer, device, ...
    source          TEXT NOT NULL,           -- 'fhir' | 'openehr' | 'hl7v2' | 'ccda' | ...
    source_ref      TEXT,                    -- the source's own id (FHIR logical id / openEHR UID)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_entries_subject ON health8.clinical_entries (subject_id);
CREATE INDEX idx_entries_type ON health8.clinical_entries (env_id, entry_type);
CREATE INDEX idx_entries_effective ON health8.clinical_entries (effective_time);
```

The `source`/`source_ref` columns record which standard wrote the entry and
its native id, so a facade can round-trip its own ids losslessly while the
canonical entry remains model-agnostic.

### 2.3 `health8.documents` / `health8.document_entries`

Documents group entries (a FHIR `Composition`, an openEHR `COMPOSITION`, an
encounter). The grouping is a many-to-many link.

```sql
CREATE TABLE health8.documents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    subject_id      UUID NOT NULL REFERENCES health8.subjects(id),
    document_type   TEXT NOT NULL,           -- 'composition' | 'encounter' | ...
    title           TEXT,
    source          TEXT NOT NULL,
    source_ref      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE health8.document_entries (
    document_id     UUID NOT NULL REFERENCES health8.documents(id) ON DELETE CASCADE,
    entry_id        UUID NOT NULL REFERENCES health8.clinical_entries(id) ON DELETE CASCADE,
    PRIMARY KEY (document_id, entry_id)
);
```

### 2.4 Versioning - `health8.versioned_objects` / `health8.versions`

A **unified version model** that is a superset of both standards' versioning:
FHIR's `meta.versionId` history and openEHR's
`CONTRIBUTION`/`VERSION`/`VERSIONED_OBJECT`. Every version is an immutable
snapshot with an audit-trailed contribution.

```sql
CREATE TABLE health8.versioned_objects (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    object_type     TEXT NOT NULL,           -- 'entry' | 'document' | 'subject'
    object_id       UUID NOT NULL,           -- the entry/document/subject id
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE health8.versions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    versioned_object_id UUID NOT NULL REFERENCES health8.versioned_objects(id) ON DELETE CASCADE,
    version_number  INTEGER NOT NULL,
    data            JSONB NOT NULL,          -- the full snapshot at this version
    contribution    JSONB NOT NULL DEFAULT '{}',  -- audit trail (who, when, why)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (versioned_object_id, version_number)
);
```

### 2.5 Search index - `health8.entry_index`

A typed search index over clinical entries, shared by both facades. FHIR
search parameters and openEHR AQL both translate to queries against this
index (each facade maps its own query vocabulary to the canonical index).

```sql
CREATE TABLE health8.entry_index (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    entry_id        UUID NOT NULL REFERENCES health8.clinical_entries(id) ON DELETE CASCADE,
    param_name      TEXT NOT NULL,           -- e.g. 'code', 'date', 'subject'
    param_type      TEXT NOT NULL,           -- string|token|reference|date|quantity|number|uri
    value_string    TEXT,
    value_token_system TEXT,
    value_token_code   TEXT,
    value_reference TEXT,
    value_date_start TIMESTAMPTZ,
    value_date_end   TIMESTAMPTZ,
    value_number    NUMERIC,
    value_quantity  NUMERIC,
    value_quantity_unit TEXT,
    value_uri       TEXT
);

CREATE INDEX idx_entry_index_env ON health8.entry_index (env_id, param_name);
CREATE INDEX idx_entry_index_token ON health8.entry_index (env_id, param_name, value_token_system, value_token_code);
CREATE INDEX idx_entry_index_date ON health8.entry_index (env_id, param_name, value_date_start, value_date_end);
```

The index is rebuilt transactionally on every create/update/delete. Each
facade declares which canonical parameters it indexes (FHIR search parameters
and openEHR AQL paths both map onto `param_name`).

### 2.6 RLS policies

```sql
ALTER TABLE health8.clinical_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE health8.clinical_entries FORCE ROW LEVEL SECURITY;

CREATE POLICY entries_tenant ON health8.clinical_entries FOR ALL USING (
    sentin8_context_initialized()
    AND (
        sentin8_bypass_rls()                                   -- platform admin
        OR env_id = sentin8_current_env_id()                   -- env-scoped
    )
);
```

Holder-scoping for patient data is enforced by the **consent-grant**
materialization (see consent design §4) - a practitioner's read of a patient's
data is gated by Shield (ReBAC relation tuple) *and* the
`health8.consent_grants` table, which CDR joins at query time for
subject-compartment entries. The `subject_id` column on `clinical_entries` is
the holder key.

## 3. API Surface

CDR exposes a **canonical** API (not FHIR, not openEHR) that the facades call.
It is an internal surface - the public surfaces are FHIR and openEHR.

### 3.1 Canonical API

| Endpoint | Purpose |
|---|---|
| `POST /v1/subjects` | Create/upsert a subject |
| `GET /v1/subjects/{id}` | Read a subject |
| `POST /v1/entries` | Create a clinical entry |
| `GET /v1/entries/{id}` | Read a clinical entry |
| `PUT /v1/entries/{id}` | Update a clinical entry |
| `DELETE /v1/entries/{id}` | Delete a clinical entry |
| `GET /v1/entries` | Search entries (canonical query) |
| `GET /v1/entries/{id}/history` | Entry version history |
| `POST /v1/documents` | Create a document |
| `GET /v1/documents/{id}` | Read a document (with entries) |

### 3.2 Internal (proxy-back) endpoints

Per the event-driven execution mandate (AGENTS.md), CDR exposes **no bespoke
`/v1/internal/...` endpoints** for cross-service reads. The facades and other
services read clinical data through CDR's canonical API (RLS-scoped). The only
proxy-back surface is for Sentin8:Func/Sentin8:Cron/Sentin8:Flow host
functions that need domain data they cannot derive from the event payload:

| Endpoint | Purpose |
|---|---|
| `POST /v1/internal/func/read-entry` | Func host function: read a clinical entry |
| `POST /v1/internal/func/search-entries` | Func host function: search entries |

These are the narrow proxy-back contract (AGENTS.md "when an internal API is
still justified"), not a new trigger surface.

## 4. Crates

| Crate | Purpose |
|---|---|
| `health8-canonical` | The canonical clinical model types (subject, entry, document, version) - shared by CDR and both facades. |
| `health8-cdr-contracts` | CDR canonical API DTOs + event payloads. |
| `health8-cdr-client` | Typed client for CDR's canonical API (used by the facades). |

## 5. Authorization

- **Step 5 gate**: `verify_token` (steps 1–4) then
  `crate::policy::require(&state.policy, &auth, &headers, EvalTarget::new("health8:cdr:<resource>:<action>"))`.
- **Consent**: subject-compartment reads require a consent-grant relation
  tuple (ReBAC) evaluated by Shield; holder-scoped RLS is the backstop.
- **Admin scopes**: `health8:cdr:admin` role with granular
  `health8:cdr:{resource}:{action}` scopes.

## 6. Events

| Event | Payload (self-contained) |
|---|---|
| `health8:cdr:entry:created` | `{ entry_id, subject_id, entry_type, code, source, source_ref }` |
| `health8:cdr:entry:updated` | `{ entry_id, subject_id, entry_type, code, source, source_ref }` |
| `health8:cdr:entry:deleted` | `{ entry_id, subject_id }` |
| `health8:cdr:document:created` | `{ document_id, subject_id, document_type, source, source_ref }` |

All events carry `env_id`, `subject_id`, `correlation_id`, `idempotency_key`.
The `source` field records which standard (`fhir` | `openehr` | …) produced the
change, so facades can filter events to their own writes.
