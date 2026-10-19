# Sentin8 Health8:Terminology - Terminology Service Technical Design

Last updated: 2026-09-09
Status: Target-state design (pre-implementation)
Owners: Sentin8 Platform Engineering, Health8 Product Engineering

> **References**: `sentin8-health8-technical-design.md` (master),
> `sentin8-health8-cdr-technical-design.md` (CDR),
> `sentin8/design/sentin8-architecture-principles.md` §4.3.

## 1. Executive Summary

Health8:Terminology owns the **code system, value set, and concept map**
domain: storage of `CodeSystem`, `ValueSet`, and `ConceptMap` FHIR resources,
plus the standard terminology `$` operations. It is the single source of truth
for coded-element validation across the vertical.

The reference platform's terminology operations (`$lookup`, `$validate-code`,
`$expand`, `$translate`, `$subsumes`, `$import`, `$closure`, `$find-matches`)
are preserved at parity, re-implemented in Rust against Sentin8:DB.

## 2. Data Model

```sql
CREATE SCHEMA IF NOT EXISTS health8;

-- Code systems (FHIR CodeSystem resources, denormalized for lookup).
CREATE TABLE health8.codesystems (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    url             TEXT NOT NULL,
    version         TEXT,
    name            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active',
    content         TEXT NOT NULL DEFAULT 'not-present',  -- not-present|example|fragment|complete|supplement
    resource        JSONB NOT NULL,                       -- full CodeSystem resource
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (env_id, url, version)
);

-- Concepts within a code system (for $lookup / $validate-code / $subsumes).
CREATE TABLE health8.concepts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    codesystem_id   UUID NOT NULL REFERENCES health8.codesystems(id) ON DELETE CASCADE,
    code            TEXT NOT NULL,
    display         TEXT,
    definition      TEXT,
    parent_code     TEXT,                                 -- hierarchy for $subsumes
    properties      JSONB NOT NULL DEFAULT '{}',
    UNIQUE (env_id, codesystem_id, code)
);

CREATE INDEX idx_concepts_cs ON health8.concepts (codesystem_id);

-- Value sets (FHIR ValueSet resources).
CREATE TABLE health8.valuesets (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    url             TEXT NOT NULL,
    version         TEXT,
    name            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active',
    resource        JSONB NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (env_id, url, version)
);

-- Concept maps (FHIR ConceptMap resources).
CREATE TABLE health8.conceptmaps (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    url             TEXT NOT NULL,
    version         TEXT,
    name            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active',
    resource        JSONB NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (env_id, url, version)
);
```

All tables: `ENABLE ROW LEVEL SECURITY` + `FORCE ROW LEVEL SECURITY` with the
standard `env_id` policy.

## 3. Operations

| Operation | Route | Description |
|---|---|---|
| `$lookup` | `POST /fhir/CodeSystem/$lookup` | Resolve a code to its display/definition/properties. |
| `$validate-code` | `POST /fhir/CodeSystem/$validate-code` | Validate a code against a code system. |
| `$validate-code` | `POST /fhir/ValueSet/$validate-code` | Validate a code against a value set. |
| `$expand` | `POST /fhir/ValueSet/$expand` | Expand a value set to its member codes. |
| `$translate` | `POST /fhir/ConceptMap/$translate` | Translate a code across concept maps. |
| `$subsumes` | `POST /fhir/CodeSystem/$subsumes` | Test subsumption between two codes. |
| `$import` | `POST /fhir/CodeSystem/$import` | Import a code system (e.g. LOINC, SNOMED). |
| `$closure` | `POST /fhir/ConceptMap/$closure` | Maintain a closure table. |
| `$find-matches` | `POST /fhir/CodeSystem/$find-matches` | Property-based code lookup. |

## 4. Import

`$import` accepts a code-system definition (URL + version) and materializes
concepts into `health8.concepts`. Large terminologies (SNOMED CT, LOINC) are
imported asynchronously: the request enqueues a `health8:terminology:import:requested`
event, a Sentin8:Func module (or a direct consumer) performs the import, and
`health8:terminology:import:completed` signals completion. The import source is
a Sentin8:Storage object (the code-system distribution file).

## 5. CDR integration

CDR validates coded elements (`code`, `Coding`, `CodeableConcept`) against
Terminology at write time when the env's `validate_codes` flag is enabled. The
validation is a synchronous read-your-writes call to Terminology's public
`$validate-code` API (RLS-scoped) - a narrow, justified internal call (the
caller needs the result in the same request).

## 6. Events

| Event | Payload |
|---|---|
| `health8:terminology:import:requested` | `{ codesystem_url, version, storage_object }` |
| `health8:terminology:import:completed` | `{ codesystem_url, version, concept_count }` |
| `health8:terminology:import:failed` | `{ codesystem_url, version, error }` |

## 7. Authorization

- Step 5 gate: `EvalTarget::new("health8:terminology:<resource>:<action>")`.
- Admin scopes: `health8:terminology:admin` role with
  `health8:terminology:codesystems:{read,write}`,
  `health8:terminology:valuesets:{read,write}`,
  `health8:terminology:conceptmaps:{read,write}`,
  `health8:terminology:import:write`.
