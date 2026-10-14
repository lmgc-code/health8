# Sentin8 Health8 — AI Integration Design

Last updated: 2026-09-09
Status: Target-state design (pre-implementation)
Owners: Sentin8 Platform Engineering, Health8 Product Engineering

> **References**: `sentin8-health8-technical-design.md` (master),
> `sentin8/design/sentin8-sentin8-ai-technical-design.md` (Sentin8:AI),
> `sentin8/design/sentin8-sentin8-func-technical-design.md` (WASM execution).

## 1. Executive Summary

Health8 consumes Sentin8:AI for clinical intelligence through the
**event-driven execution** pattern: domain events trigger Sentin8:Func modules
(WASM) that call Sentin8:AI, and the results are written back to CDR. No
Health8 service embeds AI logic directly.

## 2. Use Cases

| Use case | Trigger | AI capability |
|---|---|---|
| Clinical note summarization | `health8:cdr:entry:created` (document entry) | Text summarization |
| Coding assistance | `health8:cdr:entry:created` (observation entry) | Code suggestion (SNOMED/LOINC) |
| Risk flagging | `health8:cdr:entry:created` (observation entry) | Anomaly detection |
| Patient-message triage | `health8:workflow:task:created` | Classification |

## 3. Trigger Chain

```
health8:cdr:entry:created (document entry)
  → Sentin8:Bus relay → Valkey Stream
  → declarative trigger (vertical-registry.json event_triggers)
  → Sentin8:Func POST /v1/modules/{id}/execute (WASM module)
  → module calls Sentin8:AI (prompt registry)
  → module proxy-calls back to CDR to write the summary (a new entry)
```

## 4. Declarative Triggers

```json
{
  "event_triggers": [
    {
      "event_type": "health8:cdr:entry:created",
      "target": { "kind": "func", "module_id": "note-summarizer", "hook": "on_document" },
      "consumer_group": "health8-ai-summarizer",
      "retry": { "max_retries": 3, "backoff": "exponential" }
    }
  ]
}
```

## 5. Guardrails

- **Consent-gated**: AI modules only process resources the invoking context is
  authorized to read (RLS + Shield).
- **Idempotent**: every trigger dedupes on the event `idempotency_key`.
- **Audited**: AI writes are attributed to the module's M2M identity and
  recorded in the consent/audit trail.
- **Human-in-the-loop**: AI outputs are written as draft/annotation resources,
  never silently mutating clinical data.
