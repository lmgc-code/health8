# Sentin8 Health8:Workflow - Clinical Workflow Service Technical Design

Last updated: 2026-09-09
Status: Target-state design (pre-implementation)
Owners: Sentin8 Platform Engineering, Health8 Product Engineering

> **References**: `sentin8-health8-technical-design.md` (master),
> `sentin8-health8-cdr-technical-design.md` (CDR),
> `sentin8/design/sentin8-sentin8-cron-technical-design.md` (scheduling),
> `sentin8/design/sentin8-sentin8-flow-technical-design.md` (workflow engine).

## 1. Executive Summary

Health8:Workflow owns the **clinical task and order** domain: `Task`,
`CarePlan`, `ServiceRequest`, `Appointment`/`Schedule`/`Slot`, and order
orchestration. It delegates scheduling to Sentin8:Cron and multi-step
orchestration to Sentin8:Flow - it does not run its own scheduler or embed a
saga engine.

## 2. Domain Model

| FHIR resource | Health8:Workflow responsibility |
|---|---|
| `Task` | Clinical task state machine (ready → in-progress → completed/failed/cancelled). |
| `CarePlan` | Care plan composition and status tracking. |
| `ServiceRequest` | Order intake and fulfillment tracking. |
| `Appointment` / `Schedule` / `Slot` | Appointment booking and slot management. |
| `MedicationRequest` | Medication order lifecycle (delegated to CDR for storage, Workflow for state). |

## 3. Task State Machine

```
ready → in-progress → completed
   │         │
   │         └──→ failed
   └──→ cancelled
```

- **Transitions** are validated (no illegal transitions).
- **Completion** emits `health8:workflow:task:completed`, which CDR consumes to
  update the parent CarePlan status.
- **Scheduled tasks** (e.g. "follow-up in 2 weeks") create Sentin8:Cron
  schedules via `POST /v1/schedules` (proxied), with a proxy-back endpoint
  `POST /v1/internal/schedules/run` that Cron calls when the schedule fires.

## 4. Order Orchestration

`health8:workflow:order:placed` is the trigger for order fulfillment:

```
ServiceRequest created
  → health8:workflow:order:placed (self-contained: order id, patient, code, requester)
  → Sentin8:Flow workflow (declarative trigger) orchestrates fulfillment steps
  → each step proxy-calls back to Workflow/CDR for domain data
  → health8:workflow:task:completed on fulfillment
```

The workflow definition is a Sentin8:Flow logic (declared in
`vertical-registry.json` `event_triggers`), not embedded saga code in Workflow.

## 5. Appointments

- `Schedule`/`Slot` are stored in CDR (they are FHIR resources).
- Workflow owns the **booking logic**: slot availability, conflict detection,
  double-booking prevention (transactional slot claim).
- Appointment reminders are Sentin8:Cron schedules.

## 6. Data Model

```sql
CREATE SCHEMA IF NOT EXISTS health8;

-- Task state (denormalized from FHIR Task for the state machine).
CREATE TABLE health8.tasks (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    task_id         TEXT NOT NULL,               -- FHIR Task logical id
    status          TEXT NOT NULL DEFAULT 'ready',
    intent          TEXT NOT NULL DEFAULT 'order',
    priority        TEXT NOT NULL DEFAULT 'routine',
    patient_id      UUID,
    focus_type      TEXT,                        -- e.g. 'ServiceRequest'
    focus_id        TEXT,
    owner           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (env_id, task_id)
);

CREATE INDEX idx_tasks_env_status ON health8.tasks (env_id, status);

-- Appointment slot claims (transactional double-booking prevention).
CREATE TABLE health8.slot_claims (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    env_id          UUID NOT NULL,
    slot_id         TEXT NOT NULL,
    appointment_id  TEXT NOT NULL,
    claimed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (env_id, slot_id)
);
```

All tables: `ENABLE ROW LEVEL SECURITY` + `FORCE ROW LEVEL SECURITY` with the
standard `env_id` policy.

## 7. Events

| Event | Payload |
|---|---|
| `health8:workflow:task:completed` | `{ task_id, status, focus_type, focus_id, patient_id }` |
| `health8:workflow:order:placed` | `{ order_id, patient_id, code, requester, encounter_id }` |
| `health8:workflow:appointment:booked` | `{ appointment_id, slot_id, patient_id, start, end }` |

## 8. Authorization

- Step 5 gate: `EvalTarget::new("health8:workflow:<resource>:<action>")`.
- Admin scopes: `health8:workflow:admin` role with
  `health8:workflow:tasks:{read,write}`, `health8:workflow:careplans:{read,write}`,
  `health8:workflow:orders:{read,write}`, `health8:workflow:appointments:{read,write}`.
