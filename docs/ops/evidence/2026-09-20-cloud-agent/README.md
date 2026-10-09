# Cloud Agent VM private-beta *preparation* evidence

**Date:** 2026-09-20  
**Host:** Cursor Cloud Agent VM (Linux)  
**Commit base:** `main` tip at evidence capture start  
**Verdict:** **PRIVATE BETA NOT YET** — this archive is preparation evidence only.

This directory records what could be collected on the Cloud Agent VM. It does
**not** claim private-beta readiness. Live staging SMTP, TLS deploy, systemd
install, and representative-hardware stress remain open.

## Environment notes

| Item | Result |
| --- | --- |
| System Perl | `/usr/bin/perl` 5.38.2 — PASS (`system-perl-preflight.txt`) |
| Carton (apt) | Installed (`carton` 1.0.35) |
| PostgreSQL 16 | Client + server installed; cluster accepting connections on 5432 |
| nginx | Installed (`nginx/1.24.0`); binary on PATH |
| `make install-deps-postgres` / Carton `local/` | **Not completed** before interrupt — CPAN deps missing |
| Hypnotoad / morbo on `:8080` | **Not started** |
| Throwaway DB / DSN drills | **Not run** |

## Phase results

| Phase | Status | Artifact |
| --- | --- | --- |
| `script/gpforum-system-perl --preflight` | **pass** | `system-perl-preflight.txt` |
| `script/gpforum-private-beta-checklist --status` | **pass** (print-only; private beta not claimed) | `private-beta-checklist-status.txt` |
| `script/gpforum-private-beta-checklist --commands` | **pass** (print-only) | `private-beta-checklist-commands.txt` |
| `script/staging-host-verify --json` (repo-only) | **fail** (deps) | `staging-host-verify-repo.stderr`, empty `.json` |
| `script/staging-drill --json` | **skipped** | — |
| `script/staging-drill-attachments --json` | **skipped** | — |
| App bring-up (migrate / query-budget / seed / Hypnotoad) | **skipped** | — |
| `script/staging-host-verify --json --env-file … --base-url …` | **skipped** | — |
| `script/gpforum-mail-check --json --dry-run` | **skipped** | — |
| `script/stress-load --json --profile smoke` | **skipped** | — |
| `script/stress-load --json --profile 100` | **skipped** | — |
| systemd unit install / `--systemd` | **skipped** | No units installed on this VM |

## residual_gaps

1. **Carton `local/` not installed** — `make install-deps-postgres` did not finish; Perl modules (e.g. `Const::Fast`) missing, so carton-backed harnesses cannot run.
2. **No DSN-backed staging-drill / attachments drill** — throwaway role/DB not created; JSON not captured.
3. **No live Hypnotoad/morbo** — migrate, query-budget sync/check, seed, and HTTP health verify not run.
4. **No mail-check dry-run JSON** — transport probe not executed.
5. **No stress-load smoke / 100 JSON** — requires running app on `http://127.0.0.1:8080`.
6. **No systemd evidence** — `--systemd` intentionally omitted; residual for real staging host.
7. **No live staging TLS / SMTP `--send` / representative hardware** — still required before any private-beta go decision (see `docs/ops/staging-host.md`, `docs/release/readiness-review.md`).

## Explicit non-claim

**PRIVATE BETA: NOT YET.** Archiving this partial Cloud Agent VM prep evidence does not change the release verdict.
