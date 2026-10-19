# Sentin8 Health8:FHIR - FHIR Facade Technical Design

Last updated: 2026-09-09
Status: Target-state design (pre-implementation)
Owners: Sentin8 Platform Engineering, Health8 Product Engineering

> **References**: `sentin8-health8-technical-design.md` (master, §4.1a
> three-layer architecture, §4.2 version negotiation),
> `sentin8-health8-cdr-technical-design.md` (canonical CDR),
> `sentin8/design/sentin8-architecture-principles.md` §4.3 (defense-in-depth).

## 1. Executive Summary

Health8:FHIR is a **facade** over the canonical CDR. It exposes the
multi-version FHIR REST API (STU3/R4/R4B/R5) and maps FHIR resources ↔
canonical clinical entries. It owns **no clinical tables** - clinical data
lives in the canonical CDR; the facade owns only FHIR-specific metadata
(search-parameter definitions, the FHIR↔canonical id mapping).

The facade is the **standards layer**: it implements the FHIR REST API,
search, versioning, validation, and conformance, and delegates persistence to
the canonical CDR via its canonical API (RLS-scoped).

## 2. Scope

The FHIR facade owns:

- **Version negotiation** (master design §4.2).
- **Resource model** - the multi-version type vocabulary and JSON
  serialization.
- **Interactions** - read/vread/update/patch/delete/create/search/history/
  batch/transaction/capabilities + `$` operations.
- **Search** - search-parameter resolution, modifiers, chained parameters,
  `_include`/`_revinclude`, `_filter` (FHIRPath).
- **Versioning & concurrency** - `meta.versionId`, `meta.lastUpdated`,
  `If-Match` optimistic concurrency, history.
- **Validation** - StructureDefinition-based validation per version.
- **Conformance** - per-version `CapabilityStatement`.
- **Mapping** - FHIR resource ↔ canonical entry (the facade's core function).
- **Version conversion** - best-effort cross-version read conversion.

The engine does **not** own persistence (CDR), tenancy/RLS (platform), or
authorization (Sentin8:Policy) - those are the host service's and platform's
concerns.

## 3. Version Negotiation

The engine supports **STU3 (3.0.2), R4 (4.0.1), R4B (4.3.0), and R5 (5.0.0)**
and negotiates the FHIR version per request, resolved in this order:

1. **`fhirVersion` query parameter** - `GET /fhir/Patient?fhirVersion=4.0.1`.
2. **`Accept` header** - `Accept: application/fhir+json; fhirVersion=4.0.1`.
3. **`Content-Type` header** - for writes, the `fhirVersion` parameter on the
   request body's content type.
4. **Environment default** - `health8_default_fhir_version` (default `4.0.1`).

The negotiated version drives validation, search-parameter resolution,
serialization, and the `CapabilityStatement`.

## 4. Resource Model

The `health8-fhir` crate is the single source of truth for the resource model:

- **Typed structs** for the common clinical resources (Patient, Practitioner,
  Observation, Condition, MedicationRequest, Encounter, …).
- A **generic `Resource` envelope** (resource type + `id` + `meta` + flattened
  JSON) so no resource is ever rejected, including version-specific and
  extension-heavy resources.
- **Per-version allow-lists** - R5-only types (`ActorDefinition`,
  `Requirements`, `SubscriptionTopic`) are accepted only under R5; STU3-only
  types only under STU3. The `ResourceType` vocabulary is the union across all
  four versions.

## 5. Interactions

| Interaction | Route | Method |
|---|---|---|
| `read` | `/fhir/{type}/{id}` | GET |
| `vread` | `/fhir/{type}/{id}/_history/{vid}` | GET |
| `update` | `/fhir/{type}/{id}` | PUT |
| `patch` | `/fhir/{type}/{id}` | PATCH |
| `delete` | `/fhir/{type}/{id}` | DELETE |
| `create` | `/fhir/{type}` | POST |
| `search` | `/fhir/{type}` | GET |
| `search-system` | `/fhir` | GET |
| `history` | `/fhir/{type}/{id}/_history` | GET |
| `history-system` | `/fhir/_history` | GET |
| `batch` | `/fhir` | POST (Bundle type=batch) |
| `transaction` | `/fhir` | POST (Bundle type=transaction) |
| `capabilities` | `/fhir/metadata` | GET |
| `$everything` | `/fhir/Patient/{id}/$everything` | GET |
| `$validate` | `/fhir/{type}/$validate` | POST |
| `$meta` | `/fhir/{type}/{id}/$meta` | GET/POST/DELETE |
| `$graph` | `/fhir/{type}/{id}/$graph` | GET |

## 6. Search Engine

### 6.1 Search-parameter resolution

The engine loads the **per-version** FHIR search-parameter definitions at
startup (embedded via `include_str!` from `health8-fhir` - STU3/R4/R4B/R5) and
builds a `fhir_version → resource_type → param_name → index strategy` map.
Search requests are parsed into a typed query AST, translated to SQL against
the repository's search index (scoped by the negotiated `fhir_version`), and
executed with the RLS context set. A search parameter that does not exist in
the negotiated version returns `400 Bad Request` (unknown search parameter).

### 6.2 Supported modifiers

`:missing`, `:not`, `:exact`, `:contains`, `:text`, `:above`, `:below`,
`:in`, `:not-in`, `:of-type`, `:iterate`, chained parameters
(`Patient.name.given`), `_include`/`_revinclude`, `_sort`, `_count`,
`_total`, `_summary`, `_elements`, `_contained`, `_graph`.

### 6.3 `_filter` (FHIRPath subset)

A pragmatic FHIRPath subset is evaluated for `_filter`. The evaluator lives in
the `health8-fhir` crate and is shared by the search engine and any other
FHIRPath consumer.

## 7. Versioning & Concurrency

- **Optimistic concurrency**: `If-Match` (ETag = `W/"versionId"`) on update;
  a mismatch returns `412 Precondition Failed`.
- **`meta.versionId`** is a monotonically increasing string (ULID or
  timestamp-based) per logical id.
- **`meta.lastUpdated`** is set server-side on every write.
- **History** is immutable - history rows are never updated or deleted (except
  by a future `$expunge` operation, out of v1 scope).

## 8. Validation

Resources are validated against the **StructureDefinition** set for the
negotiated version (embedded in `health8-fhir`). Validation covers:

- Required elements, cardinality, and element types.
- Coded elements (against Terminology, when the env's `validate_codes` flag
  is enabled).
- References (existence and type, where checkable).

Validation failures return an `OperationOutcome` with `422 Unprocessable
Entity`.

## 9. Version Conversion

Storage is version-agnostic: resources are stored in a canonical internal form
tagged with the `fhir_version` they were written in. On read, the engine
converts the stored form to the requested version where the resource is
version-compatible, and returns `422 Unprocessable Entity` (or a
`CapabilityStatement`-declared unsupported-version error) where a cross-version
conversion is not defined. Same-version reads are lossless; cross-version reads
are best-effort and version-aware.

## 10. Conformance

`GET /fhir/metadata` returns the `CapabilityStatement` for the negotiated
version, generated from the same registration data the service self-describes
(interactions, search parameters, operations, and supported versions).

## 11. Mapping - FHIR resource ↔ canonical entry

The facade's core function is the **mapping** between FHIR resources and the
canonical CDR's clinical entries. The facade calls the canonical CDR API
(CDR §3.1) - it does not touch the CDR's tables directly.

```rust
// The facade maps a FHIR resource to/from a canonical entry.
fn resource_to_entry(resource: &Resource) -> Vec<CanonicalEntry>;
fn entry_to_resource(entry: &CanonicalEntry) -> Resource;
```

- **FHIR → canonical**: a FHIR `Observation` maps to a canonical entry of
  `entry_type = "observation"` with `code`, `value`, `effective_time`, and
  `subject_id`; a FHIR `Patient` maps to a canonical `subject`; a FHIR
  `Composition` maps to a canonical `document` linking its entries.
- **canonical → FHIR**: the reverse mapping reconstructs the FHIR resource
  from the canonical entry, using the `source`/`source_ref` columns to
  round-trip the FHIR logical id losslessly.
- **Search**: FHIR search parameters are translated to queries against the
  canonical `health8.entry_index` (CDR §2.5).
- **Versioning**: FHIR `meta.versionId` history maps onto the canonical
  unified version model (CDR §2.4).

The mapping is **per-standard and well-defined** (not a lossy cross-standard
bridge): the canonical model is a superset of FHIR's semantics, so the
round-trip is lossless for FHIR-native data.

## 12. Crates

| Crate | Purpose |
|---|---|
| `health8-fhir` | Multi-version FHIR type definitions (serde) for STU3/R4/R4B/R5, per-version search-parameter definitions, FHIRPath evaluator, JSON validation, and version conversion. |
| `health8-canonical` | The canonical clinical model types (shared with CDR and the openEHR facade). |
| `health8-cdr-client` | Typed client for CDR's canonical API (used by the facade). |
