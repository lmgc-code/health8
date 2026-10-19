# Health8 Design Docs

Design set for the **Health8 vertical** - Sentin8's healthcare domain
(canonical clinical data repository with FHIR + openEHR facades, terminology,
interoperability, clinical workflow, consent) - built as Rust services on the
Sentin8 platform.

## Reading order

1. `sentin8-health8-technical-design.md` - **master** architecture: what is
   kept (clinical domain), what is replaced (platform machinery), the service
   catalog (CDR / FHIR / OpenEHR / Terminology / Interop / Workflow / Consent),
   tenancy, identity bridge, event taxonomy, SMART scope mapping, FHIR version
   negotiation (§4.2), openEHR dual-model support (§4.3), deployment modes
   (§4.4), the three-layer architecture (§4.1a), phases.
2. `sentin8-health8-cdr-technical-design.md` - **CDR**: the canonical,
   model-agnostic clinical data repository (subjects, entries, documents,
   versioning, index) - the single source of truth.
3. `sentin8-health8-fhir-technical-design.md` - **FHIR facade**: the
   multi-version FHIR (STU3/R4/R4B/R5) standards layer, mapping FHIR resources
   ↔ canonical entries.
4. `sentin8-health8-openehr-technical-design.md` - **openEHR facade**: the
   dual-model openEHR standards layer (RM + archetypes/templates + AQL),
   mapping compositions ↔ canonical entries.
5. `sentin8-health8-terminology-technical-design.md` - **Terminology**:
   CodeSystem/ValueSet/ConceptMap + `$lookup`/`$validate-code`/`$expand`/
   `$translate`/`$subsumes`/`$import`.
6. `sentin8-health8-interop-technical-design.md` - **Interop**: HL7 v2 MLLP,
   C-CDA exchange, Bulk Data export, SMART conformance, subscriptions/FHIRcast.
7. `sentin8-health8-workflow-technical-design.md` - **Workflow**: Task,
   CarePlan, ServiceRequest, appointments, order orchestration.
8. `sentin8-health8-consent-technical-design.md` - **Consent**: patient-directed
   access, data minimization, audit, Shield ReBAC + holder-scoped RLS.
9. `sentin8-health8-data-model-technical-design.md` - **Data model**: full
   table catalog, RLS policies, per-service PG roles.
10. `sentin8-health8-apps-technical-design.md` - **Apps**: eHealth, eClinician,
    eAdmin + RFW admin pages.
11. `sentin8-health8-cli-technical-design.md` - **CLI**: `health8-cli` vertical
    tooling.
12. `sentin8-health8-ai-integration-design.md` - **AI**: Sentin8:AI consumption
    via event-driven Sentin8:Func modules.

Backlog: `../BACKLOG.md`.

## One-line summary

Keep every FHIR resource, search parameter, terminology operation, and
interoperability format - across STU3, R4, R4B, and R5 - plus the openEHR
dual-model (Reference Model + archetypes/templates + AQL), both as facades
over one canonical, model-agnostic clinical data repository; delete the OAuth
server, hand-rolled schema, background-job queue, storage abstraction, web app,
and metrics stack - all of that is Sentin8 platform surface
(Auth/DB/Storage/Bus/Cron/Func/Flow/TLS/Stat/Dash/BFF).

## Shared Architecture

See `../sentin8/design/sentin8-architecture-principles.md` for platform-wide
architecture, tenant model, and authorization pipeline.
