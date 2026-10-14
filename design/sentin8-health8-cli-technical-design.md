# Sentin8 Health8 — Vertical CLI Technical Design

Last updated: 2026-09-09
Status: Target-state design (pre-implementation)
Owners: Sentin8 Platform Engineering, Health8 Product Engineering

> **References**: `sentin8-health8-technical-design.md` (master),
> `sentin8/design/sentin8-sentin8-cli-technical-design.md` (platform CLI),
> `sentin8/design/sentin8-architecture-principles.md` §4.14 (zero compile-time
> vertical knowledge).

## 1. Executive Summary

Health8 ships a **vertical CLI** (`health8-cli`) for healthcare-specific
tooling that does not belong in the platform CLI (`sentin8-cli`). The platform
CLI must never reference `health8.*` tables or logic (principles §4.14).

The vertical CLI follows the `email8-cli` pattern: a `cmd/cli` crate in the
Health8 workspace, binary `health8-cli`, with a `lib.rs` for testability.

## 2. Commands

| Command | Purpose |
|---|---|
| `health8-cli import-terminology <url> <version> <file>` | Import a code-system distribution (LOINC, SNOMED) into Terminology. |
| `health8-cli export-ccda <composition-id>` | Export a Composition as a C-CDA document. |
| `health8-cli import-ccda <file>` | Import a C-CDA document into CDR. |
| `health8-cli bulk-export <scope> [--type ...]` | Trigger a Bulk Data export. |
| `health8-cli seed-demo` | Seed a demo environment (patients, practitioners, observations, consents). |

## 3. Design

- **`cmd/cli` crate** — binary `health8-cli`, lib `health8_cli`.
- **clap** for argument parsing (same as `email8-cli`).
- **No platform-CLI dependency** — the vertical CLI calls Health8 services
  directly (or via the shared SDK), never through `sentin8-cli`.
- **Terminology import** is asynchronous: the CLI enqueues the import event and
  polls for completion (or the operator uses the RFW admin page).

## 4. Crate Layout

```
health8/cmd/cli/
  Cargo.toml
  src/
    main.rs       — clap entry point
    lib.rs        — re-exports for testability
    terminology.rs — import-terminology
    ccda.rs        — export/import C-CDA
    bulk.rs        — bulk-export
    seed.rs        — seed-demo
```
