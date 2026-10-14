# Sentin8 Health8 — Vertical Technical Design (Master)

Last updated: 2026-09-09
Status: Target-state design (pre-implementation)
Owners: Sentin8 Platform Engineering, Health8 Product Engineering

> **References**: `sentin8/design/sentin8-architecture-principles.md` (platform principles),
> `sentin8/design/sentin8-sentin8-bus-technical-design.md` (inbox-first events),
> `sentin8/design/sentin8-sentin8-bff-technical-design.md` (client access + transport tiers),
> `sentin8/design/sentin8-sentin8-storage-technical-design.md` (object storage),
> `sentin8/design/sentin8-sentin8-auth-technical-design.md` (identity, M2M, DCR),
> `sentin8/design/sentin8-service-self-registration-design.md` (runtime registration),
> `sentin8/design/sentin8-sentin8-func-technical-design.md` (WASM execution),
> `sentin8/design/sentin8-sentin8-flow-technical-design.md` (workflow engine),
> `sentin8/design/sentin8-sentin8-cron-technical-design.md` (scheduling).
> Per-service design docs in `health8/design/`.

## 1. Executive Summary

Health8 is Sentin8's **healthcare vertical**: a multi-tenant, FHIR®-native,
interoperable clinical data platform re-implemented as **Rust services on the
Sentin8 platform**, with Flutter clinical apps and Dash RFW admin pages.

Health8 provides a **canonical clinical data repository (CDR)** — a
model-agnostic store of clinical data (subjects, entries, documents,
versioning, index) — exposed through **two standards facades**: a
standards-complete, **multi-version FHIR** facade supporting **STU3 (3.0.2),
R4 (4.0.1), R4B (4.3.0), and R5 (5.0.0)** with full CRUD, search, history,
versioning, batch/transaction, and compartment semantics; and a **dual-model
openEHR** facade (Reference Model + archetypes/templates,
`CONTRIBUTION`/`VERSION` versioning, and AQL query). Health8 also provides a
**terminology service** (CodeSystem, ValueSet, ConceptMap with the standard
`$` operations); an **interoperability service** (HL7 v2 messaging, C-CDA
document exchange, Bulk Data export, SMART on FHIR conformance, and event
subscriptions); a **clinical workflow service** (Task,
CarePlan, ServiceRequest, appointments, scheduling); and a **consent service**
(FHIR Consent, patient-directed access, data minimization, audit).

The reference healthcare platform this design is derived from is a
**distributed monolith**: one Node.js process serving FHIR CRUD/search,
terminology, bulk export, SMART OAuth, subscriptions, HL7 v2, C-CDA, DICOM,
clinical decision support, server-side "bots", an on-premise agent, and SCIM
provisioning — with its own OAuth2/OIDC authorization server, its own
PostgreSQL schema with hand-rolled search-parameter indexing, its own
background-job queue, its own storage abstraction, and its own web app. All of
that platform machinery is **replaced, not ported** — Health8 keeps only the
*clinical/healthcare domain* and wires it into Sentin8:Auth, Sentin8:DB,
Sentin8:Storage, Sentin8:Bus, Sentin8:Cron, Sentin8:Func, Sentin8:Flow,
Sentin8:Proxy/TLS, Sentin8:Captain, Sentin8:Dash, Sentin8:BFF and
Sentin8:Stat.

### 1.1 What Health8 replaces

| Reference platform capability | Health8 vertical on Sentin8 |
|---|---|
| Built-in OAuth2/OIDC authorization server (authorize/token/introspect/userinfo, DCR, JWKS) | **Deleted.** Sentin8:Auth is the single identity plane (principles §4.1). SMART on FHIR scopes (`patient/*.read`, `user/*.write`, `system/*.read`) map to Sentin8 granular scopes (`health8:fhir:patient:read`, …) at the BFF/authorization layer. |
| SMART App Launch (launch context, `launch/patient`, `fhirUser`, `aud`/`iss` claims) | **Kept as a domain concern** — the SMART conformance document (`/.well-known/smart-configuration`) and launch-context resolution are served by Health8:Interop, but the OAuth mechanics (authorization code, PKCE, token minting, `aud`/`iss`/`fhirUser` claims) are Sentin8:Auth's job. |
| Hand-rolled PostgreSQL schema with per-resource-type tables + search-parameter lookup tables + token columns | **Replaced.** A canonical model (`health8.subjects`, `health8.clinical_entries`, `health8.documents`, `health8.versioned_objects`, `health8.versions`, `health8.entry_index`) with RLS (`env_id` + `subject_id` holder-scoping). FHIR and openEHR are facades over this canonical store. |
| Background-job queue (Redis) for bulk export / async operations | **Replaced.** Sentin8:Bus (Valkey Streams) for fire-and-forget triggers + Sentin8:Cron for scheduled work + Sentin8:Flow for multi-step workflows. |
| Server-side "bots" (AWS Lambda / in-process) | **Replaced.** Sentin8:Func (WASM modules) with the proxy-back pattern for domain data access. |
| On-premise agent (HL7 v2 MLLP listener, DICOM, channel management) | **Replaced.** Health8:Interop owns HL7 v2 MLLP over Sentin8:TLS raw-TCP; DICOM is deferred (see §3). |
| SCIM 2.0 provisioning server | **Deferred/optional** — provisioning becomes Sentin8:Auth events consumed by Health8 (`sentin8:auth:user:created` → patient/practitioner bootstrap). |
| Web app (React SPA) | **Replaced.** Flutter apps (eHealth patient portal, eClinician, eAdmin) via Sentin8:BFF + RFW admin pages rendered by Sentin8:Dash. |
| Metrics/tracing stack | **Replaced.** Sentin8:Stat + `tracing` structured logs. |
| Storage abstraction (S3/Azure/file) | **Replaced.** Sentin8:Storage for Binary resources, DICOM objects, and bulk-export artifacts. |

### 1.2 What deliberately does NOT change

The **clinical domain itself** is preserved at parity — every FHIR resource,
search parameter, operation, and interoperability format that makes a
healthcare platform correct:

- **Multi-version FHIR** resource model: all ~150 resource types (Patient,
  Practitioner, Observation, Condition, MedicationRequest, Encounter,
  DiagnosticReport, Immunization, AllergyIntolerance, CarePlan, CareTeam,
  Procedure, …) across **STU3, R4, R4B, and R5**, with full JSON
  serialization, `meta.versionId`/`meta.lastUpdated` versioning, `_history`,
  `_format`, `_summary`, `_elements`, `_pretty`, `_total`, `_count`, `_sort`,
  `_include`/`_revinclude`, `_contained`, `_graph`. The FHIR version is
  negotiated per request (see §4.2).
- **Search**: the full FHIR search-parameter set (string, token, reference,
  date, quantity, number, uri, composite, special `_text`/`_content`/`_filter`),
  chained parameters, `:missing`, `:not`, `:exact`, `:contains`, `:above`/`:below`,
  `:in`/`:not-in`, `:of-type`, `:iterate`.
- **Interactions**: `read`, `vread`, `update`, `patch`, `delete`, `create`,
  `search`, `search-system`, `history`, `history-system`, `batch`, `transaction`,
  `capabilities`, `$everything`, `$validate`, `$meta`, `$graph`, `$export`.
- **Terminology operations**: `$lookup`, `$validate-code`, `$expand`,
  `$translate`, `$subsumes`, `$import`, `$closure`, `$find-matches`.
- **Interoperability formats**: HL7 v2 (ADT/ORU/ORM/ORU-R01, MLLP framing,
  ACK/NAK), C-CDA (R1.1/R2.1) export/import, Bulk Data (FHIR Bulk Data Access
  IG STU2 — group/patient/system export, NDJSON, `_since`, `_type`).
- **SMART on FHIR**: App Launch (EHR launch + standalone launch), scopes
  (`patient/*.read`, `user/*.write`, `system/*.read`), launch context
  (`launch/patient`, `launch/encounter`), `fhirUser`, `aud`/`iss` claims.
- **Subscriptions**: FHIR `Subscription` resource (R4/R4B) and
  `SubscriptionTopic` (R5), REST-hook + websocket channels,
  `SubscriptionStatus` notifications, FHIRcast topic-based events.
- **openEHR (dual-model)**: the Reference Model (`COMPOSITION`, `OBSERVATION`,
  `EVALUATION`, `INSTRUCTION`, `ACTION`, `ADMIN_ENTRY`, `CLUSTER`, `ELEMENT`,
  `SECTION`, `ENTRY`), archetypes/templates (AOM 1.4/2.x), the
  `CONTRIBUTION`/`VERSION`/`VERSIONED_OBJECT` versioning model, `EHR`/`EHR_STATUS`
  records, and **AQL** (Archetype Query Language) — see §4.3.

## 2. Goals

- Re-implement every clinical capability in Rust as **seven vertical services**
  (below) on Sentin8:DB, Storage, Bus, Cron, Func, Flow, Auth, TLS/Proxy,
  Captain, Stat, Dash, BFF.
- **Multi-tenant by environment.** Each Sentin8 env is an isolated clinical
  tenant: own patients, practitioners, terminology, consents, audit. RLS on
  every table (`env_id` + `patient_id` holder-scoping); explicit `WHERE env_id`
  clauses as defense-in-depth.
- **Multi-version FHIR conformance** — a `CapabilityStatement` per supported
  FHIR version (STU3/R4/R4B/R5) that accurately describes the implemented
  surface, generated from the same registration data the service
  self-describes.
- **openEHR conformance** — an openEHR REST API (EHRbase-compatible surface)
  and AQL query endpoint, with archetype/template validation against the
  operational template set.
- **Consent-first data access** — every patient-data read is gated by a
  patient-directed consent (FHIR `Consent`) evaluated at the authorization
  layer (Sentin8:Policy Shield) *and* enforced by holder-scoped RLS.
- **Event-driven execution** — cross-service work (order → result, encounter
  → billing, immunization → registry) is expressed as `health8:*` domain events
  with self-contained payloads, idempotency keys, and DLQ replay.

## 3. Non-Goals

- Health8 does not issue tokens, API keys, or sessions — Sentin8:Auth is the
  only issuer.
- Health8 does not run its own scheduler — all scheduling is delegated to
  Sentin8:Cron.
- Health8 does not compile or run WASM directly — clinical decision support and
  custom hooks are delegated to Sentin8:Func.
- Health8 does not implement DICOM imaging in v1 (deferred — see §3.1).
- Health8 does not implement clinical decision support (CDS) rules natively —
  CDS is Sentin8:Func modules triggered by `health8:*` events.
- Health8 does not provide arbitrary SQL or tenant-authored RLS policies.
- Health8 does not implement billing/claims (that is a future vertical or a
  bank8 integration concern).

### 3.1 Out-of-scope / deferred capabilities

| Capability | Rationale |
|---|---|
| DICOM (DICOMweb STOW-RS/QIDO-RS/WADO-RS) | Deferred to a later phase; `ImagingStudy`/`Media` FHIR resources are supported, but the DICOM binary protocol is out of v1 scope. |
| CDS Hooks (decision support service) | Replaced by Sentin8:Func modules triggered by `health8:*` events; the CDS Hooks HTTP contract is deferred. |
| SCIM 2.0 provisioning | Replaced by Sentin8:Auth events (`sentin8:auth:user:created` → patient/practitioner bootstrap). |
| FHIR R6 / future releases | v1 targets STU3, R4, R4B, and R5; R6 is added when HL7 publishes it. |
| GraphQL API | The reference platform's GraphQL surface is not ported; FHIR REST is the API. |
| Billing / claims / ExplanationOfBenefit processing | Out of scope; `Claim`/`ExplanationOfBenefit` resources are storable but not adjudicated. |

## 4. Service Catalog

| Service | `service_type` | Binary | Role |
|---|---|---|---|
| Health8:CDR | `health8:cdr` | `health8-cdr` | Canonical clinical data repository — model-agnostic store (subjects, entries, documents, versioning, index). |
| Health8:FHIR | `health8:fhir` | `health8-fhir` | FHIR facade — multi-version FHIR (STU3/R4/R4B/R5) REST API, mapping FHIR resources ↔ CDR canonical entries. |
| Health8:OpenEHR | `health8:openehr` | `health8-openehr` | openEHR facade — dual-model openEHR REST API + AQL, mapping compositions ↔ CDR canonical entries. |
| Health8:Terminology | `health8:terminology` | `health8-terminology` | CodeSystem/ValueSet/ConceptMap storage + `$lookup`/`$validate-code`/`$expand`/`$translate`/`$subsumes`/`$import`. |
| Health8:Interop | `health8:interop` | `health8-interop` | HL7 v2 MLLP, C-CDA exchange, Bulk Data export, SMART conformance, subscriptions/FHIRcast. |
| Health8:Workflow | `health8:workflow` | `health8-workflow` | Task, CarePlan, ServiceRequest, Appointment/Schedule/Slot, order orchestration. |
| Health8:Consent | `health8:consent` | `health8-consent` | FHIR Consent, patient-directed access, data minimization, audit trail. |

### 4.1 Service responsibilities and boundaries

```
                    ┌──────────────────────────────────────────────┐
                    │              Sentin8 platform                │
                    │  auth · bff · db · storage · bus · tls       │
                    │  captain · app · flow · func · cron · stat   │
                    └───────────────┬──────────────────────────────┘
                                    │  runtime registration + relative deps
   ┌──────────────┬──────────────┬──────────────┬──────────────┬──────────────┬──────────────┬──────────────┐
   │ health8:fhir │health8:oehr  │ health8:cdr  │health8:term  │health8:interop│health8:workflow│health8:consent│
   │  FHIR facade │ openEHR fac. │ canonical CDR│  terminology │ HL7v2/C-CDA  │  Task/CarePlan│  Consent/audit│
   └──────────────┴──────────────┴──────────────┴──────────────┴──────────────┴──────────────┴──────────────┘
```

- **Health8:CDR** is the **canonical clinical data repository** — the single
  writer of the canonical tables (`health8.subjects`,
  `health8.clinical_entries`, `health8.documents`, `health8.versioned_objects`,
  `health8.versions`, `health8.entry_index`). It is model-agnostic: no FHIR or
  openEHR concepts. The facades read/write through CDR's canonical API
  (RLS-scoped) — never by direct table access.
- **Health8:FHIR** is a **facade** — it exposes the multi-version FHIR REST
  API and maps FHIR resources ↔ canonical entries. It owns no clinical tables
  (only its own FHIR-specific metadata, e.g. search-parameter definitions).
- **Health8:OpenEHR** is a **facade** — it exposes the openEHR REST API + AQL
  and maps compositions ↔ canonical entries. It owns no clinical tables (only
  its own openEHR-specific metadata, e.g. archetypes/templates).
- **Health8:Terminology** owns `health8.codesystems`, `health8.valuesets`,
  `health8.conceptmaps` and serves the `$` operations. The facades validate
  coded elements against Terminology at write time (configurable per env).
- **Health8:Interop** owns the wire-format adapters (HL7 v2, C-CDA, NDJSON)
  and the Bulk Data export pipeline. It converts to/from FHIR and calls the
  FHIR facade (or CDR) for persistence.
- **Health8:Workflow** owns clinical task state and delegates scheduling to
  Sentin8:Cron and multi-step orchestration to Sentin8:Flow.
- **Health8:Consent** owns `health8.consents` and the consent-decision
  evaluation that feeds both Sentin8:Policy (Shield) and holder-scoped RLS.

### 4.1a Three-layer architecture — canonical CDR + standards facades

The core architectural decision is a **three-layer** split:

1. **Canonical CDR** — one model-agnostic clinical store (the single source
   of truth).
2. **FHIR facade** — maps FHIR ↔ canonical.
3. **openEHR facade** — maps openEHR ↔ canonical.

**Why a canonical model, not two native stores.** FHIR and openEHR are **not
isomorphic** — FHIR is single-model (flat resources + extensions + profiles),
openEHR is dual-model (RM + archetypes/templates + `CONTRIBUTION`/`VERSION`).
A direct mapping between them is lossy. Two independent native stores would
mean either (a) duplicated clinical data with no single source of truth, or
(b) a lossy cross-standard bridge as the *only* link. A canonical model
resolves this: each facade maps its standard to/from the canonical model (a
well-defined, per-standard mapping), so both standards can be used
**simultaneously** against the same clinical data without either being a
degraded projection of the other.

**Why the facades are separate services.** Each facade is a different domain
with a different model, query language, versioning, validation, and API
surface:

| Dimension | FHIR facade | openEHR facade |
|---|---|---|
| Model | Single-model (flat resource types) | Dual-model (RM + archetypes/templates) |
| Query | FHIR search parameters + `_filter` | AQL |
| Versioning | `meta.versionId` history | `CONTRIBUTION`/`VERSION`/`VERSIONED_OBJECT` |
| Validation | StructureDefinition | Archetype/template (AOM/ADL) |
| API | FHIR REST | EHRbase-compatible REST |

Separating them gives independent scaling, failure isolation, cleaner
authorization (`health8:fhir:*` vs `health8:openehr:*` scopes), and
independent evolution. The shared concerns — tenancy, RLS, consent, auth,
events — are **platform-provided** (the shell, policy engine, and RLS helpers
give a new service those for free), so there is no co-location pressure.

**The canonical model is internal, not a new public standard.** The public
surfaces are FHIR and openEHR (and the Interop formats). The canonical model
exists to make those surfaces consistent — and to make adding a third
standard (HL7 v2, C-CDA, a future FHIR R6) a matter of writing one more
facade, not re-architecting the store.

### 4.2 FHIR version negotiation

Health8:FHIR is a **multi-version FHIR facade**. It supports **STU3 (3.0.2),
R4 (4.0.1), R4B (4.3.0), and R5 (5.0.0)** and negotiates the FHIR version per
request. The version is resolved in this order:

1. **`fhirVersion` query parameter** — `GET /fhir/Patient?fhirVersion=4.0.1`
   (the FHIR R4+ standard mechanism).
2. **`Accept` header** — `Accept: application/fhir+json; fhirVersion=4.0.1`.
3. **`Content-Type` header** — for writes, the `fhirVersion` parameter on the
   request body's content type.
4. **Environment default** — the env's configured default FHIR version
   (`health8_default_fhir_version`, default `4.0.1`).

The negotiated version drives:

- **Resource validation** — the resource is validated against the
  StructureDefinition set for that version (the `health8-fhir` crate embeds
  the STU3/R4/R4B/R5 definitions).
- **Search parameters** — the search-parameter vocabulary differs across
  versions (e.g. R5 adds `_filter`-only parameters, R4B renames some); the
  engine resolves parameters against the negotiated version's definitions.
- **Serialization** — responses are serialized in the negotiated version's
  dialect (element names, `resourceType` casing, extension URLs).
- **CapabilityStatement** — `GET /fhir/metadata` returns the
  `CapabilityStatement` for the negotiated version.

**Storage is version-agnostic.** Resources are mapped to the canonical CDR's
model (which is version-agnostic) and tagged with the `fhir_version` they were
written in. On read, the facade converts the canonical form to the requested
version where the resource is version-compatible, and returns a `422
Unprocessable Entity` (or a `CapabilityStatement`-declared unsupported-version
error) where a cross-version conversion is not defined.
This mirrors the FHIR "version conversion" model: same-version reads are
lossless; cross-version reads are best-effort and version-aware.

**Version-specific resource types.** R5-only resource types (e.g.
`ActorDefinition`, `Requirements`, `SubscriptionTopic`) are accepted only when
the negotiated version is R5; STU3-only types are accepted only under STU3.
The `ResourceType` vocabulary in `health8-fhir` is the union across all four
versions, with a per-version allow-list.

### 4.3 openEHR (dual-model) support

Health8:OpenEHR is a **facade** over the canonical CDR. It exposes the
dual-model openEHR surface and maps compositions ↔ canonical entries. openEHR
is not mapped into a FHIR resource table — the canonical model is the shared
store, and each facade maps its own standard to/from it (see §4.1a).

**Why a facade, not a native store.** FHIR is single-model (flat resource
types with fixed search parameters); openEHR is dual-model (a stable Reference
Model + archetypes/templates that define clinical content) with its own
versioning model (`CONTRIBUTION`/`VERSION`/`VERSIONED_OBJECT`) and its own
query language (AQL). The openEHR facade preserves all of that at the API
surface, while the canonical CDR stores the underlying clinical facts in a
model-agnostic form. Archetype structure, template semantics, and the
contribution/version audit trail are preserved by the facade (stored as
openEHR-specific metadata the facade owns), not discarded.

**Reference Model (RM).** The openEHR RM is supported at parity:

- `EHR` / `EHR_STATUS` — the top-level record and its status.
- `COMPOSITION` — the clinical document container (with `SECTION` and
  `ENTRY` children).
- `ENTRY` subtypes — `OBSERVATION`, `EVALUATION`, `INSTRUCTION`, `ACTION`,
  `ADMIN_ENTRY`.
- `CLUSTER`, `ELEMENT`, `ITEM_TREE`, `ITEM_LIST`, `ITEM_SINGLE`, `ITEM_TABLE`.
- `PARTY` (party self/identified/related), `PARTICIPATION`, `EVENT_CONTEXT`.
- Data types (`DV_TEXT`, `DV_CODED_TEXT`, `DV_QUANTITY`, `DV_DATE_TIME`,
  `DV_COUNT`, `DV_PROPORTION`, `DV_ORDINAL`, `DV_URI`, `DV_IDENTIFIER`, …).

**Archetypes & templates (AOM).** Archetypes (AOM 1.4/2.x, ADL 1.4/2) and
operational templates (OPT) are stored and validated by the facade. The
operational template set is the env's clinical content contract; compositions
are validated against their template at write time.

**Versioning.** openEHR's `CONTRIBUTION`/`VERSION`/`VERSIONED_OBJECT` model is
preserved at the API surface. The facade maps it onto the canonical CDR's
unified version model (CDR §2.4), which is a superset of both FHIR's
`meta.versionId` history and openEHR's contribution/version model.

**AQL.** The Archetype Query Language is supported via a dedicated query
endpoint. AQL queries are parsed and translated to queries against the
canonical CDR's entry index (CDR §2.5), executed with the RLS context set
(same tenant/consent isolation as FHIR).

**REST API.** The openEHR surface follows the EHRbase-compatible REST
conventions:

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

**Storage.** The facade owns only openEHR-specific metadata (archetypes,
templates, and the mapping of openEHR UIDs to canonical ids). Clinical data
lives in the canonical CDR. The facade's metadata tables are env-scoped with
`FORCE ROW LEVEL SECURITY`.

### 4.4 Deployment modes

The canonical model makes the "which standard is authoritative" question moot:
**the canonical CDR is always the system of record**, and FHIR and openEHR are
always projections over it. There is no lossy cross-standard bridge — each
facade maps its own standard to/from the canonical model, and both are usable
simultaneously at full native fidelity.

Two deployment modes remain, selected per environment:

| Mode | Description |
|---|---|
| **Both facades** (default) | FHIR and openEHR are both enabled; both map to the canonical CDR. |
| **Single facade** | Only one facade is enabled (FHIR-only or openEHR-only); the other is not deployed. |

The earlier "FHIR facade over openEHR" and "hybrid" modes are **subsumed** by
the canonical model: instead of FHIR being a lossy projection of openEHR (or
vice versa), both are clean projections of the canonical CDR. A tenant that
wants openEHR as its primary clinical model simply uses the openEHR facade as
its main surface; FHIR remains available as a second, equally-faithful surface
over the same data.

### 4.4a Using both standards simultaneously

**Yes — FHIR and openEHR can be used at the same time, by construction.** Both
facades map to the same canonical CDR, so:

- a FHIR app (e.g. a SMART app) and an openEHR app (e.g. an AQL-driven
  clinical analytics tool) run **at the same time**, against the same clinical
  data;
- a write via FHIR is visible via AQL (and vice versa), because both read the
  canonical store;
- both facades run **at full native fidelity** — neither is a degraded
  projection of the other, because the canonical model is a superset of both.

The canonical CDR is the single source of truth; FHIR and openEHR are two
interchangeable projections over it.

## 5. Tenancy & Isolation

### 5.1 Tenant model

Each Sentin8 **environment** is an isolated clinical tenant. `env_id` is
globally unique (principles §4.1). A patient, practitioner, or organization
belongs to exactly one env. Cross-env access is validated at the authorization
layer (no blanket org-wide bypass).

### 5.2 RLS patterns

- **Env-scoped tables** (`health8.subjects`, `health8.clinical_entries`,
  `health8.documents`, `health8.versioned_objects`, `health8.versions`,
  `health8.entry_index`, `health8.codesystems`, `health8.valuesets`,
  `health8.conceptmaps`, `health8.consents`, `health8.tasks`,
  `health8.subscriptions`): standard `env_id` policy.
- **Holder-scoped tables** (patient data): the `health8.clinical_entries`
  table uses a **holder-scoped** policy — a row is visible if `env_id` matches
  AND the caller is either (a) the patient themselves
  (`subject_id = current_user`), (b) a practitioner with a valid consent, or
  (c) a platform/env admin. The consent check is materialized into a
  `health8.consent_grants` table (see consent design §4) so RLS can evaluate
  it without a per-row join.
- **`FORCE ROW LEVEL SECURITY`** on every tenant table. `set_tenant_context`
  is `async` and `.await`ed on the same connection as the data query
  (principles §4.3d).

### 5.3 Per-service PostgreSQL roles

Each service has its own DCR-registered M2M client whose OAuth scopes map to a
per-service PostgreSQL role (principles §4.3e):

| Service | PG role | Scopes |
|---|---|---|
| Health8:CDR | `health8_cdr_service` | `health8:cdr:read,health8:cdr:write` |
| Health8:FHIR | `health8_fhir_service` | `health8:fhir:read,health8:fhir:write` |
| Health8:OpenEHR | `health8_openehr_service` | `health8:openehr:read,health8:openehr:write` |
| Health8:Terminology | `health8_terminology_service` | `health8:terminology:read,health8:terminology:write` |
| Health8:Interop | `health8_interop_service` | `health8:interop:read,health8:interop:write` |
| Health8:Workflow | `health8_workflow_service` | `health8:workflow:read,health8:workflow:write` |
| Health8:Consent | `health8_consent_service` | `health8:consent:read,health8:consent:write` |

## 6. Event Taxonomy

All event names follow the `vertical:service:resource:operation` convention
(AGENTS.md). Self-contained envelopes carry `event_type`, `env_id`,
`subject_id`, `correlation_id`, `idempotency_key`, and the full domain
snapshot the consumer needs. CDR emits canonical `entry`/`document` events;
the facades emit their own standard-specific events.

| Event | Producer | Consumers (declarative triggers) |
|---|---|---|
| `health8:cdr:entry:created` | CDR | Interop (subscription fan-out), Workflow (order intake), Consent (auto-consent review) |
| `health8:cdr:entry:updated` | CDR | Interop (subscription fan-out) |
| `health8:cdr:entry:deleted` | CDR | Interop (subscription fan-out) |
| `health8:cdr:document:created` | CDR | Interop (subscription fan-out) |
| `health8:fhir:resource:created` | FHIR | Interop (subscription fan-out) |
| `health8:openehr:composition:committed` | OpenEHR | Interop (subscription fan-out), Consent (auto-consent review) |
| `health8:openehr:template:uploaded` | OpenEHR | Interop (metadata) |
| `health8:workflow:task:completed` | Workflow | CDR (CarePlan status update), Interop (notification) |
| `health8:workflow:order:placed` | Workflow | CDR (ServiceRequest), Interop (HL7 ORM outbound) |
| `health8:consent:granted` | Consent | CDR (recompute consent_grants), Interop (audit) |
| `health8:consent:revoked` | Consent | CDR (recompute consent_grants), Interop (audit) |
| `health8:interop:bulkexport:completed` | Interop | CDR (artifact link), Stat (telemetry) |
| `sentin8:auth:user:created` | Sentin8:Auth | CDR (subject bootstrap), Consent (default consent) |
| `sentin8:sys:service:updated` | Sentin8:Sys | All (env-init seeding) |

## 7. Authorization

### 7.1 SMART on FHIR scope mapping

SMART scopes are the healthcare-standard authorization vocabulary. They map to
Sentin8 granular scopes at the BFF/authorization layer:

| SMART scope | Sentin8 scope |
|---|---|
| `patient/Patient.read` | `health8:fhir:patient:read` |
| `patient/Observation.read` | `health8:fhir:observation:read` |
| `patient/*.read` | `health8:fhir:patient:read` (wildcard expands to the patient-data read set) |
| `user/*.write` | `health8:fhir:write` (user-level write) |
| `system/*.read` | `health8:fhir:system:read` (system-level read) |
| `launch/patient` | launch context (not a scope — a launch parameter) |
| `openid` / `fhirUser` | Sentin8:Auth `openid` / `profile` |

### 7.2 Standard authorization pipeline

Every Health8 service follows the standard 8-step pipeline (principles §5):
extract bearer → verify → resolve tenant → feature gate → **authorize via
Sentin8:Policy (Shield — RBAC + ABAC + ReBAC)** → set RLS context → execute →
emit audit. The JWT `scope` claim is a coarse pre-filter + RLS context feed;
the Shield engine is the decision (policy design §4.3).

### 7.3 Consent as an authorization input

Patient-directed consent is a **first-class authorization input**, not a
business-logic afterthought:

- A `health8:consent:granted` event recomputes `health8.consent_grants`
  (materialized `(env_id, patient_id, grantee_id, scope, purpose)` rows).
- Shield policies reference the consent grant relation (ReBAC) — a practitioner
  can read a patient's data only if a consent-grant relation tuple exists.
- Holder-scoped RLS is the backstop: even if Shield mis-evaluates, the row is
  invisible without a matching grant.

## 8. Implementation Phases

| Phase | Scope | Status |
|---|---|---|
| 0 | Platform prerequisites (raw-TCP TLS for MLLP, Storage HEAD/dedup) | ☐ |
| 1 | Workspace skeleton + contracts + service scaffolds + SQL | ☐ |
| 2 | CDR canonical model (subjects, entries, documents, versioning, index) | ☐ |
| 3 | FHIR facade (CRUD, search, history, versioning) | ☐ |
| 4 | openEHR facade (RM, AOM, AQL) | ☐ |
| 5 | Terminology (`$` operations) | ☐ |
| 6 | Interop (HL7 v2, C-CDA, Bulk Data, SMART, subscriptions) | ☐ |
| 7 | Workflow (Task/CarePlan/ServiceRequest/appointments) | ☐ |
| 8 | Consent (grants, data minimization, audit) | ☐ |
| 9 | Apps (eHealth, eClinician, eAdmin) + RFW admin pages | ☐ |
| 10 | E2E + packaging + hardening | ☐ |

## 9. Suggested Sentin8 platform additions

Two Health8 needs are **generic platform capabilities**, not clinical logic:

1. **Sentin8:TLS raw-TCP listener support** (platform) — for HL7 v2 MLLP
   (minimal lower-layer protocol) over TLS. Same generic capability Email8
   already requested for SMTP/IMAP STARTTLS. No clinical knowledge.
2. **Sentin8:Storage `HEAD`/dedup fast path** (platform) — for Binary
   resources and bulk-export artifacts (content-addressed dedup). Same
   generic capability Email8 requested.

Both are listed in the Health8 backlog as platform-blocking stories.
