# Sentin8 Health8 — Data Model & Persistence Technical Design

Last updated: 2026-09-09
Status: Target-state design (pre-implementation)
Owners: Sentin8 Platform Engineering, Health8 Product Engineering

> **References**: `sentin8-health8-technical-design.md` (master),
> `sentin8/design/sentin8-sentin8-db-technical-design.md` (RLS context),
> `sentin8/design/sentin8-architecture-principles.md` §4.3 (defense-in-depth).

## 1. Executive Summary

This document is the **authoritative table catalog** for the Health8 vertical.
All tables live in the `health8` schema. Every tenant table has
`ENABLE ROW LEVEL SECURITY` + `FORCE ROW LEVEL SECURITY` and the standard
`env_id` policy; patient-compartment tables additionally use holder-scoped
policies backed by `health8.consent_grants`.

The per-service design docs (`cdr`, `fhir`, `openehr`, `terminology`,
`interop`, `workflow`, `consent`) each define their own tables; this document
consolidates the
cross-cutting conventions and the full catalog.

## 2. Tenant Column Conventions

- Every tenant table: `env_id UUID NOT NULL`.
- Patient-compartment tables: `patient_id UUID` (nullable for non-patient
  resources).
- All tables: `ENABLE ROW LEVEL SECURITY` + `FORCE ROW LEVEL SECURITY`.
- Standard env policy:

```sql
CREATE POLICY tenant_isolation ON health8.<table> FOR ALL USING (
    sentin8_context_initialized()
    AND (
        sentin8_bypass_rls()                                   -- platform admin
        OR env_id = sentin8_current_env_id()                   -- env-scoped
    )
);
```

- Holder-scoped policy (patient data):

```sql
CREATE POLICY holder_isolation ON health8.<table> FOR ALL USING (
    sentin8_context_initialized()
    AND (
        sentin8_bypass_rls()
        OR env_id = sentin8_current_env_id()
           AND (
               patient_id = sentin8_current_user_id()          -- the patient
               OR EXISTS (                                     -- consented grantee
                   SELECT 1 FROM health8.consent_grants g
                   WHERE g.env_id = sentin8_current_env_id()
                     AND g.patient_id = <table>.patient_id
                     AND g.grantee_id = sentin8_current_user_id()
                     AND g.active
               )
           )
    )
);
```

## 3. Full Table Catalog

| Table | Owner | Scope | Notes |
|---|---|---|---|
| `health8.subjects` | CDR | env + holder | Canonical subject (patient/practitioner/…) |
| `health8.clinical_entries` | CDR | env + holder | Canonical clinical entry (the atomic unit) |
| `health8.documents` | CDR | env + holder | Canonical document (grouping of entries) |
| `health8.document_entries` | CDR | env | Document ↔ entry link |
| `health8.versioned_objects` | CDR | env | Canonical versioned object |
| `health8.versions` | CDR | env | Canonical version snapshot (unified version model) |
| `health8.entry_index` | CDR | env | Canonical search index (shared by facades) |
| `health8.templates` | OpenEHR | env | openEHR operational templates (OPT) — facade metadata |
| `health8.archetypes` | OpenEHR | env | openEHR archetypes (AOM/ADL) — facade metadata |
| `health8.openehr_id_map` | OpenEHR | env | openEHR UID ↔ canonical id mapping |
| `health8.codesystems` | Terminology | env | CodeSystem resources |
| `health8.concepts` | Terminology | env | CodeSystem concepts (for `$` ops) |
| `health8.valuesets` | Terminology | env | ValueSet resources |
| `health8.conceptmaps` | Terminology | env | ConceptMap resources |
| `health8.hl7_destinations` | Interop | env | HL7 v2 outbound destinations |
| `health8.bulk_exports` | Interop | env | Bulk Data export jobs |
| `health8.subscriptions` | Interop | env | FHIR Subscription mirror |
| `health8.tasks` | Workflow | env | Task state machine |
| `health8.slot_claims` | Workflow | env | Appointment slot claims |
| `health8.consents` | Consent | env | FHIR Consent resources |
| `health8.consent_grants` | Consent | env | Materialized consent grants (Shield + RLS) |
| `health8.consent_audit` | Consent | env | Immutable consent audit trail |

## 4. Per-Service PostgreSQL Roles

| Service | PG role | Bypass RLS |
|---|---|---|
| Health8:CDR | `health8_cdr_service` | no |
| Health8:FHIR | `health8_fhir_service` | no |
| Health8:OpenEHR | `health8_openehr_service` | no |
| Health8:Terminology | `health8_terminology_service` | no |
| Health8:Interop | `health8_interop_service` | no |
| Health8:Workflow | `health8_workflow_service` | no |
| Health8:Consent | `health8_consent_service` | no |

Only `sentin8_bus_relay` (scoped to `sentin8_bus_inbox`) may bypass RLS
(principles §4.3e). No Health8 service bypasses RLS.

## 5. Connection Pooling

All services use `sentin8_config::pg_pool::connect(url)` (caps
`max_connections` at 3, overridable via `SENTIN8_PG_POOL_MAX`) — never
`sqlx::PgPool::connect` directly (principles §4.3).

## 6. Table Creation

Table creation is a separate stage from service startup (principles §6.5):
`sentin8-cli vertical init` applies the SQL, `vertical enroll` registers the
services, then `start`. Health8 ships its SQL in `services/*/sql/init.sql`,
applied via the self-registration `sql_migrations` section.
