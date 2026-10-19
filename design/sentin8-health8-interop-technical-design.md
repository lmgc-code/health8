# Sentin8 Health8:Interop - Interoperability Service Technical Design

Last updated: 2026-09-09
Status: Target-state design (pre-implementation)
Owners: Sentin8 Platform Engineering, Health8 Product Engineering

> **References**: `sentin8-health8-technical-design.md` (master),
> `sentin8-health8-cdr-technical-design.md` (CDR),
> `sentin8/design/sentin8-sentin8-bus-technical-design.md` (subscriptions),
> `sentin8/design/sentin8-sentin8-storage-technical-design.md` (bulk export artifacts).

## 1. Executive Summary

Health8:Interop owns the **wire-format adapters** and the **bulk data export**
pipeline: HL7 v2 messaging (MLLP), C-CDA document exchange, FHIR Bulk Data
export (NDJSON), SMART on FHIR conformance, and FHIR subscriptions/FHIRcast.
It converts between external formats and FHIR, delegating persistence to the
FHIR facade (which maps to the canonical CDR).

## 2. HL7 v2 (MLLP)

### 2.1 Listener

Health8:Interop listens for HL7 v2 messages over **MLLP** (minimal lower-layer
protocol) on a raw-TCP listener (Sentin8:TLS raw-TCP mode - platform addition
§9 of the master design). Message types: ADT (admit/discharge/transfer), ORM
(order), ORU (result), ACK.

```
MLLP frame: <VT> ... <FS> <CR>
```

### 2.2 Pipeline

```
MLLP frame → parse (MSH/PID/OBR/OBX segments) → map to FHIR
  → CDR create/update → ACK (AA/AR/AE) → emit health8:interop:hl7:processed
```

- **ACK/NAK**: every message is acknowledged (AA = accepted, AR = rejected,
  AE = error). NAK carries an ERR segment.
- **Mapping**: ADT→Patient/Encounter, ORM→ServiceRequest, ORU→Observation/
  DiagnosticReport. The mapping is a pure function in the `health8-hl7` crate.
- **Idempotency**: the MSH-10 (message control id) is the idempotency key -
  duplicate messages are acknowledged without re-processing.

### 2.3 Outbound

`health8:cdr:entry:created` and `health8:workflow:order:placed` events
trigger outbound HL7 (ORU/ORM) to configured destinations (declarative
`event_triggers` in `vertical-registry.json`).

## 3. C-CDA

### 3.1 Export

`GET /fhir/Composition/{id}/$cda` (or `$document`) renders a Composition into
a C-CDA R2.1 document (XML). The `health8-ccda` crate implements the
FHIR→C-CDA mapping (templates, OIDs, null flavors).

### 3.2 Import

`POST /fhir/Binary` with a C-CDA document (or `$extract`) parses the C-CDA XML
into FHIR resources (Patient, Encounter, Observation, Medication, …) and
creates them in CDR.

## 4. Bulk Data Export

### 4.1 Flow

```
POST /fhir/$export (or /fhir/Patient/$export, /fhir/Group/{id}/$export)
  → create AsyncJob (status=accepted)
  → enqueue health8:interop:bulkexport:requested
  → worker (direct consumer) streams NDJSON to Sentin8:Storage
  → health8:interop:bulkexport:completed (with artifact URLs)
  → GET /fhir/$export/{id} returns the manifest (or 202 while in progress)
```

### 4.2 Parameters

`_type`, `_since`, `_outputFormat` (ndjson), `_typeFilter`. The export is
RLS-scoped - only resources the caller can read are exported.

### 4.3 Artifacts

NDJSON files are written to Sentin8:Storage (content-addressed). The manifest
(`BulkDataExport` resource) references them by URL. Artifacts are
time-limited (presigned URLs) and deleted after a retention window.

## 5. SMART on FHIR

### 5.1 Conformance

`GET /.well-known/smart-configuration` returns the SMART App Launch
conformance document. The OAuth mechanics (authorization code, PKCE, token
minting, `aud`/`iss`/`fhirUser` claims) are Sentin8:Auth's job; Health8:Interop
serves the conformance document and resolves launch context.

### 5.2 Launch context

`launch/patient` and `launch/encounter` are resolved from the launch context
stored at authorization time. The `fhirUser` claim maps to a
Patient/Practitioner/RelatedPerson resource in CDR.

## 6. Subscriptions & FHIRcast

### 6.1 FHIR Subscription (R4/R4B) and SubscriptionTopic (R5)

`Subscription` resources (R4/R4B, stored in CDR) declare a `criteria` (search
expression) and a `channel` (rest-hook or websocket). In R5, the equivalent is
the `SubscriptionTopic` + `Subscription` pair. Interop consumes
`health8:cdr:entry:*` events, matches them against active subscriptions for
the negotiated FHIR version, and delivers `SubscriptionStatus` notifications.

### 6.2 FHIRcast

Topic-based events (patient-open, patient-close, imagingstudy-open) are
published over WebSocket (the platform's bidirectional transport tier) and
SSE. FHIRcast is a domain concern of Interop.

> **Note - no openEHR↔FHIR bridge.** With the canonical CDR (master design
> §4.1a), there is no lossy cross-standard bridge: FHIR and openEHR are both
> facades over the same canonical store, so a write via one is visible via the
> other by construction. Interop's conversion work is limited to *external*
> formats (HL7 v2, C-CDA) → FHIR, not FHIR ↔ openEHR.

## 7. Data Model

```sql
CREATE SCHEMA IF NOT EXISTS health8;

-- HL7 v2 destinations (outbound).
CREATE TABLE health8.hl7_destinations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    name            TEXT NOT NULL,
    host            TEXT NOT NULL,
    port            INTEGER NOT NULL,
    tls             BOOLEAN NOT NULL DEFAULT TRUE,
    message_types   JSONB NOT NULL DEFAULT '[]',   -- e.g. ["ORU","ORM"]
    status          TEXT NOT NULL DEFAULT 'active',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Bulk export jobs.
CREATE TABLE health8.bulk_exports (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    status          TEXT NOT NULL DEFAULT 'accepted',  -- accepted|in-progress|completed|error|cancelled
    request         JSONB NOT NULL,
    output          JSONB NOT NULL DEFAULT '[]',
    error           JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at    TIMESTAMPTZ
);

-- Active subscriptions (mirror of FHIR Subscription resources, denormalized).
CREATE TABLE health8.subscriptions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    subscription_id TEXT NOT NULL,               -- FHIR Subscription logical id
    criteria        TEXT NOT NULL,
    channel_type    TEXT NOT NULL,               -- rest-hook|websocket
    endpoint        TEXT,
    status          TEXT NOT NULL DEFAULT 'active',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

All tables: `ENABLE ROW LEVEL SECURITY` + `FORCE ROW LEVEL SECURITY` with the
standard `env_id` policy.

## 8. Events

| Event | Payload |
|---|---|
| `health8:interop:hl7:processed` | `{ message_control_id, message_type, outcome, resource_refs }` |
| `health8:interop:bulkexport:requested` | `{ export_id, scope, params }` |
| `health8:interop:bulkexport:completed` | `{ export_id, artifact_urls }` |
| `health8:interop:bulkexport:failed` | `{ export_id, error }` |
| `health8:interop:subscription:notified` | `{ subscription_id, resource_type, logical_id }` |

## 9. Authorization

- Step 5 gate: `EvalTarget::new("health8:interop:<resource>:<action>")`.
- Admin scopes: `health8:interop:admin` role with
  `health8:interop:hl7:{read,write}`, `health8:interop:bulkexport:{read,write}`,
  `health8:interop:subscriptions:{read,write}`.
