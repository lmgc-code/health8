# Sentin8 Health8:OpenEHR - openEHR Facade Technical Design

Last updated: 2026-09-09
Status: Target-state design (pre-implementation)
Owners: Sentin8 Platform Engineering, Health8 Product Engineering

> **References**: `sentin8-health8-technical-design.md` (master, §4.1a
> three-layer architecture, §4.3 openEHR support),
> `sentin8-health8-cdr-technical-design.md` (canonical CDR),
> `sentin8/design/sentin8-sentin8-db-technical-design.md` (RLS context),
> `sentin8/design/sentin8-architecture-principles.md` §4.3 (defense-in-depth),
> `sentin8/design/sentin8-policy-technical-design.md` (Shield authorization).

## 1. Executive Summary

Health8:OpenEHR is a **facade** over the canonical CDR. It exposes the
dual-model openEHR surface (Reference Model + archetypes/templates +
`CONTRIBUTION`/`VERSION` versioning + AQL) and maps compositions ↔ canonical
clinical entries. It owns **no clinical tables** - clinical data lives in the
canonical CDR; the facade owns only openEHR-specific metadata (archetypes,
templates, and the openEHR UID ↔ canonical id mapping).

The facade is the **standards layer**: it implements the openEHR REST API and
AQL, and delegates persistence to the canonical CDR via its canonical API
(RLS-scoped).

## 2. Data Model - openEHR metadata (not clinical data)

The facade owns only openEHR-specific **metadata**. Clinical data (subjects,
entries, documents, versioning, index) lives in the canonical CDR (CDR §2).
The facade's tables are:

```sql
CREATE SCHEMA IF NOT EXISTS health8;

-- Operational templates (OPT) - the env's clinical content contract.
CREATE TABLE health8.templates (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    template_id     TEXT NOT NULL,
    concept         TEXT,
    opt             JSONB NOT NULL,           -- operational template (OPT 1.4/2)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (env_id, template_id)
);

-- Archetypes (AOM/ADL) - the building blocks of templates.
CREATE TABLE health8.archetypes (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    archetype_id    TEXT NOT NULL,
    adl_version     TEXT NOT NULL,            -- '1.4' | '2'
    archetype       JSONB NOT NULL,           -- archetype (AOM) body
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (env_id, archetype_id)
);

-- openEHR UID ↔ canonical id mapping - lets the facade round-trip openEHR
-- UIDs (EHR id, composition UID, version UID) to canonical CDR ids losslessly.
CREATE TABLE health8.openehr_id_map (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    openehr_uid     TEXT NOT NULL,            -- openEHR UID (EHR id / composition UID / version UID)
    canonical_id    UUID NOT NULL,            -- the canonical CDR id (subject/entry/document/version)
    kind            TEXT NOT NULL,            -- 'ehr' | 'composition' | 'version'
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (env_id, openehr_uid)
);
```

All tables: `ENABLE ROW LEVEL SECURITY` + `FORCE ROW LEVEL SECURITY` with the
standard `env_id` policy. The `openehr_id_map` is the facade's round-trip
mechanism: it maps openEHR's UIDs to the canonical CDR's ids, so the facade
can reconstruct openEHR objects from canonical data without storing clinical
data itself.

## 3. Reference Model (RM)

The openEHR RM is supported at parity:

- `EHR` / `EHR_STATUS` - the top-level record and its status.
- `COMPOSITION` - the clinical document container (with `SECTION` and
  `ENTRY` children).
- `ENTRY` subtypes - `OBSERVATION`, `EVALUATION`, `INSTRUCTION`, `ACTION`,
  `ADMIN_ENTRY`.
- `CLUSTER`, `ELEMENT`, `ITEM_TREE`, `ITEM_LIST`, `ITEM_SINGLE`, `ITEM_TABLE`.
- `PARTY` (party self/identified/related), `PARTICIPATION`, `EVENT_CONTEXT`.
- Data types (`DV_TEXT`, `DV_CODED_TEXT`, `DV_QUANTITY`, `DV_DATE_TIME`,
  `DV_COUNT`, `DV_PROPORTION`, `DV_ORDINAL`, `DV_URI`, `DV_IDENTIFIER`, …).

## 4. Archetypes & Templates (AOM)

Archetypes (AOM 1.4/2.x, ADL 1.4/2) and operational templates (OPT) are stored
and validated by the facade. The operational template set is the env's
clinical content contract; compositions are validated against their template
at write time.

## 5. Versioning

openEHR's `CONTRIBUTION`/`VERSION`/`VERSIONED_OBJECT` model is preserved at
the API surface. The facade maps it onto the canonical CDR's unified version
model (CDR §2.4), which is a superset of both FHIR's `meta.versionId` history
and openEHR's contribution/version model. The `openehr_id_map` records the
openEHR version UID ↔ canonical version id mapping.

## 6. AQL

The Archetype Query Language is supported via a dedicated query endpoint. AQL
queries are parsed and translated to queries against the canonical CDR's
entry index (CDR §2.5), executed with the RLS context set (same
tenant/consent isolation as FHIR).

## 7. REST API

The openEHR surface follows the EHRbase-compatible REST conventions:

| Endpoint | Purpose |
|---|---|
| `POST /openehr/v1/ehr` | Create an EHR |
| `GET /openehr/v1/ehr/{ehr_id}` | Read an EHR |
| `PUT /openehr/v1/ehr/{ehr_id}/ehr_status` | Update EHR status |
| `POST /openehr/v1/ehr/{ehr_id}/composition` | Commit a composition |
| `GET /openehr/v1/ehr/{ehr_id}/composition/{uid}` | Read a composition |
| `GET /openehr/v1/ehr/{ehr_id}/composition` | List compositions |
| `GET /openehr/v1/definition/template/adl1.4` | List operational templates |
| `POST /openehr/v1/definition/template/adl1.4` | Upload a template |
| `GET /openehr/v1/query/aql` | Execute an AQL query |

## 8. Crates

| Crate | Purpose |
|---|---|
| `health8-openehr` | openEHR Reference Model types (serde), archetype/template (AOM/ADL) parsing, AQL parser. |
| `health8-canonical` | The canonical clinical model types (shared with CDR and the FHIR facade). |
| `health8-cdr-client` | Typed client for CDR's canonical API (used by the facade). |

## 9. Authorization

- **Step 5 gate**: `verify_token` (steps 1-4) then
  `crate::policy::require(&state.policy, &auth, &headers, EvalTarget::new("health8:openehr:<resource>:<action>"))`.
- **Consent**: subject-compartment reads require a consent-grant relation
  tuple (ReBAC) evaluated by Shield; holder-scoped RLS is the backstop.
- **Admin scopes**: `health8:openehr:admin` role with granular
  `health8:openehr:ehr:{read,write}`, `health8:openehr:composition:{read,write}`,
  `health8:openehr:template:{read,write}`, `health8:openehr:archetype:{read,write}`,
  `health8:openehr:query:read`.

## 10. Events

| Event | Payload (self-contained) |
|---|---|
| `health8:openehr:composition:committed` | `{ ehr_id, composition_uid, template_id, subject_id, contribution_uid }` |
| `health8:openehr:template:uploaded` | `{ template_id, concept }` |
| `health8:openehr:ehr:created` | `{ ehr_id, subject_id, system_id }` |

All events carry `env_id`, `subject_id`, `correlation_id`, `idempotency_key`.
