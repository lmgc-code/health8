# Sentin8 Health8:Consent — Consent & Data Minimization Technical Design

Last updated: 2026-09-09
Status: Target-state design (pre-implementation)
Owners: Sentin8 Platform Engineering, Health8 Product Engineering

> **References**: `sentin8-health8-technical-design.md` (master),
> `sentin8-health8-cdr-technical-design.md` (CDR),
> `sentin8/design/sentin8-policy-technical-design.md` (Shield ReBAC),
> `sentin8/design/sentin8-architecture-principles.md` §4.3c (holder-scoped RLS).

## 1. Executive Summary

Health8:Consent owns the **patient-directed consent** domain: FHIR `Consent`
resources, the materialized consent-grant table that feeds both Shield (ReBAC)
and holder-scoped RLS, data minimization, and the consent audit trail.

Consent is a **first-class authorization input** — not a business-logic
afterthought. A practitioner can read a patient's data only if a consent-grant
relation tuple exists (Shield ReBAC) *and* the holder-scoped RLS policy sees a
matching grant row.

## 2. Data Model

```sql
CREATE SCHEMA IF NOT EXISTS health8;

-- FHIR Consent resources (denormalized).
CREATE TABLE health8.consents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    consent_id      TEXT NOT NULL,               -- FHIR Consent logical id
    patient_id      UUID NOT NULL,
    status          TEXT NOT NULL DEFAULT 'draft',  -- draft|active|inactive|entered-in-error
    scope           JSONB NOT NULL DEFAULT '{}',    -- { code, system }
    category        JSONB NOT NULL DEFAULT '[]',
    provision       JSONB NOT NULL DEFAULT '{}',    -- data minimization rules
    resource        JSONB NOT NULL,               -- full Consent resource
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (env_id, consent_id)
);

CREATE INDEX idx_consents_patient ON health8.consents (patient_id);

-- Materialized consent grants — the single source of truth for both Shield
-- (ReBAC relation tuples) and holder-scoped RLS. Recomputed on every
-- consent grant/revoke event.
CREATE TABLE health8.consent_grants (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    patient_id      UUID NOT NULL,
    grantee_id      UUID NOT NULL,               -- practitioner/org/related-person
    grantee_type    TEXT NOT NULL,               -- practitioner|organization|relatedperson|patient
    scope           TEXT NOT NULL,               -- e.g. 'health8:cdr:entry:read'
    purpose         TEXT,                        -- treatment|payment|operations|research
    resource_types  JSONB NOT NULL DEFAULT '[]',  -- data minimization: allowed resource types
    active          BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at      TIMESTAMPTZ,
    UNIQUE (env_id, patient_id, grantee_id, scope, purpose)
);

CREATE INDEX idx_grants_patient ON health8.consent_grants (patient_id) WHERE active;
CREATE INDEX idx_grants_grantee ON health8.consent_grants (grantee_id) WHERE active;

-- Consent audit trail (immutable).
CREATE TABLE health8.consent_audit (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    consent_id      TEXT NOT NULL,
    patient_id      UUID NOT NULL,
    action          TEXT NOT NULL,               -- granted|revoked|modified|expired
    actor           TEXT NOT NULL,               -- who performed the action
    detail          JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

All tables: `ENABLE ROW LEVEL SECURITY` + `FORCE ROW LEVEL SECURITY` with the
standard `env_id` policy.

## 3. Grant Lifecycle

```
Consent created (draft)
  → patient signs (active)
  → health8:consent:granted → recompute health8.consent_grants
  → Shield relation tuple + RLS grant row both reflect the grant

Consent revoked (inactive)
  → health8:consent:revoked → deactivate grant rows (active=false)
  → Shield relation tuple removed + RLS grant row deactivated
```

The recompute is idempotent (keyed on the consent id) and transactional — a
grant and its audit row are written atomically.

## 4. Data Minimization

The `provision` element of a Consent carries data-minimization rules (which
resource types, which date ranges, which purposes). These are materialized
into `consent_grants.resource_types` and `purpose`. CDR's holder-scoped RLS
and Shield policies both honor them:

- A grant scoped to `Observation` only does not authorize `MedicationRequest`
  reads.
- A grant with `purpose=treatment` does not authorize `purpose=research` use.

## 5. Authorization Integration

### 5.1 Shield (ReBAC)

The consent grant is a **relation tuple** in the Shield policy graph:

```
relation: patient {patient_id} → grantee {grantee_id} on resource {patient_id}
```

A Shield policy permits `health8:cdr:entry:read` when the principal has a
consent-grant relation to the subject. The relation is materialized
from `health8.consent_grants` (active rows only).

### 5.2 Holder-scoped RLS (backstop)

CDR's patient-compartment reads join `health8.consent_grants` at query time —
even if Shield mis-evaluates, the row is invisible without a matching active
grant. This is the defense-in-depth backstop (principles §4.3c).

## 6. Events

| Event | Payload |
|---|---|
| `health8:consent:granted` | `{ consent_id, patient_id, grantee_id, scope, purpose, resource_types }` |
| `health8:consent:revoked` | `{ consent_id, patient_id, grantee_id, scope }` |
| `health8:consent:expired` | `{ consent_id, patient_id }` |

## 7. Authorization

- Step 5 gate: `EvalTarget::new("health8:consent:<resource>:<action>")`.
- Admin scopes: `health8:consent:admin` role with
  `health8:consent:consents:{read,write}`, `health8:consent:grants:{read,write}`,
  `health8:consent:audit:read`.
