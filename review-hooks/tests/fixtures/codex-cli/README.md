# Codex CLI JSONL fixtures

Sanitized real captures from **codex-cli 0.146.0** `exec --json`, taken
2026-08-07 during the E2 spikes (`plans/codex-backend-spike-results.md`).
Thread ids zeroed; event structure, field names, ordering, and usage numbers
preserved.

| Fixture | Origin |
| --- | --- |
| `success.jsonl` | real run with `features.token_budget.enabled=true`; shows the terminal `turn.completed` usage shape (tokens only — no USD, no model identity) and that the enabled budget feature emits no budget events |
| `isolated.jsonl` | real adversarial isolation probe using the spike plan's **exact E2.4 argv** (disposable `CODEX_HOME`, `--ask-for-approval never`, `--output-schema`, `--ephemeral`, `--ignore-user-config`, `--ignore-rules`, read-only sandbox, all 24 `--disable` flags); shows the sentinel-instruction leak (`BANANA-7741` prefixes even inside schema-constrained output), the still-advertised exec/collaboration tool inventory, and the CLI rejecting the two deprecated web-search disables as error events while proceeding |
| `budget-exhausted.jsonl` | **DOES NOT EXIST and cannot be captured on 0.146.0** — the CLI exposes no per-run budget limit in any config location (proved by strict-config rejection of every candidate key; see spike results E2.1), so no budget-exhaustion event stream exists to record. Capture one when a codex release ships an enforceable limit. |
