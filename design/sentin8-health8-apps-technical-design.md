# Sentin8 Health8 - Apps Technical Design

Last updated: 2026-09-09
Status: Target-state design (pre-implementation)
Owners: Sentin8 Platform Engineering, Health8 Product Engineering

> **References**: `sentin8-health8-technical-design.md` (master),
> `sentin8/design/sentin8-flutter-component-library.md` (Flutter SDK),
> `sentin8/design/sentin8-design-system.md` (design system),
> `sentin8/design/sentin8-architecture-principles.md` §4.15 (RFW admin UI).

## 1. Executive Summary

Health8 ships three Flutter apps and RFW admin pages:

| App | Slug | Audience |
|---|---|---|
| Health8:eHealth | `ehealth` | Patient portal - view records, manage consents, appointments |
| Health8:eClinician | `eclinician` | Clinician - patient search, orders, results, tasks |
| Health8:eAdmin | `eadmin` | Staff - terminology, subscriptions, bulk export, audit |

All apps route through `Bff8ApiClient → Sentin8:BFF /proxy/health8/...` - no
direct service calls (Flutter SDK convention). Admin pages are RFW definitions
served by each service at `GET /v1/admin/ui/{page}` and rendered by
Sentin8:Dash.

## 2. App Structure (sentin8_flutter scaffold)

```
apps/ehealth/
  lib/
    main.dart              - bootstrap + shell (sentin8_flutter)
    bff/                   - Bff8ApiClient wiring, scope map
    pages/
      records.dart         - patient record viewer (FHIR resources)
      consents.dart        - consent management
      appointments.dart    - appointment booking
    theme/                 - Health8 brand (Royal Gold accent, Inter)
```

## 3. Scopes

### 3.1 eHealth (patient)

`health8:fhir:patient:read`, `health8:consent:consents:read`,
`health8:consent:consents:write`, `health8:workflow:appointments:read`,
`health8:workflow:appointments:write`.

### 3.2 eClinician (clinician)

`health8:fhir:patient:read`, `health8:fhir:write`,
`health8:workflow:tasks:read`, `health8:workflow:tasks:write`,
`health8:workflow:orders:read`, `health8:workflow:orders:write`,
`health8:terminology:codesystems:read`, `health8:terminology:valuesets:read`.

### 3.3 eAdmin (staff)

`health8:cdr:admin`, `health8:fhir:admin`, `health8:openehr:admin`,
`health8:terminology:admin`, `health8:interop:admin`, `health8:workflow:admin`,
`health8:consent:admin`.

## 4. RFW Admin Pages

Each service declares its admin pages in `registration.rs` (RFW definitions +
Material Icons code points). Sentin8:Dash discovers them at runtime.

| Service | Pages |
|---|---|
| CDR | overview, subjects, entries, documents, versions, index |
| FHIR | resources, search-index, history |
| OpenEHR | ehr, compositions, templates, archetypes |
| Terminology | codesystems, valuesets, conceptmaps, imports |
| Interop | hl7-destinations, bulk-exports, subscriptions |
| Workflow | tasks, careplans, orders, appointments |
| Consent | consents, grants, audit |

## 5. App Store Listings

Each app has an `app.json` with listing metadata (name, slug, description,
backend URL, OAuth defaults, scopes). Registered at runtime via
`sentin8-cli vertical enroll` (no hardcoded app-slug→backend mappings -
principles §4.8).
