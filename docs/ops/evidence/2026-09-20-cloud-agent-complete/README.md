# Cloud Agent VM complete-sequence evidence

**Date:** 2026-09-20  
**Host:** Cursor Cloud Agent VM (Linux)  
**Commit base:** `main` `@2236b47`  
**Verdict:** **PRIVATE BETA NOT YET** — preparation / incomplete-deps evidence only.

This archive records the full Cloud Agent sequence after `apt` install of
PostgreSQL/nginx and a started local cluster. Carton `local/` was still
incomplete when drills were attempted (`Const::Fast` missing), so JSON drills
were skipped. See `bootstrap-deps.log.tail.txt` and `carton-status.txt`.

## Environment notes

| Item | Result |
| --- | --- |
| System Perl | `/usr/bin/perl` 5.38.2 — PASS (`system-perl-preflight.txt`) |
| Carton (apt) | Installed (`carton` 1.0.35) |
| `script/bootstrap-deps --postgres --rebuild-local` | **In progress / incomplete** at evidence cut — see log tail |
| `carton_ok` (`Const::Fast` + `Mojo::Base`) | **FAIL** |
| PostgreSQL 16 | Installed; cluster accepting on `127.0.0.1:5432`; role/DB `gpforum` created |
| nginx | Installed (`nginx/1.24.0`); binary on PATH |
| Hypnotoad / morbo on `:8080` | **Not started** |
| Stress-load | **Not run** |

## Phase results

| Phase | Status | Artifact |
| --- | --- | --- |
| `git pull --ff-only origin main` | **pass** (`2236b47`) | — |
| apt install (build-essential, libpq-dev, postgresql, nginx, curl) | **pass** | — |
| PostgreSQL start + drill role/DB | **pass** | — |
| `script/gpforum-system-perl --preflight` | **pass** | `system-perl-preflight.txt` |
| `script/bootstrap-deps --postgres --rebuild-local` | **incomplete** | `bootstrap-deps.log.tail.txt`, `carton-status.txt` |
| `script/staging-host-verify --json` | **skipped** (deps) | `staging-host-verify.json`, `.stderr`, `.exit` |
| `script/staging-drill-attachments --json` | **skipped** (deps) | `staging-drill-attachments.json`, `.stderr`, `.exit` |
| `script/staging-drill --json` (DSN set) | **skipped** (deps) | `staging-drill.json`, `.stderr`, `.exit` |
| `script/gpforum-mail-check --json --dry-run` | **skipped** (deps) | `gpforum-mail-check-dry.json`, `.stderr`, `.exit` |
| Hypnotoad `:8080` + `stress-load` smoke | **skipped** | residual |

## residual_gaps

1. **Carton `local/` incomplete** — `script/bootstrap-deps --postgres --rebuild-local` had not finished; `Const::Fast` / Mojo app commands cannot load. Log tail archived; re-run bootstrap to completion on a durable host.
2. **No DSN-backed staging-drill / attachments drill JSON** — attempted with `GPFORUM_DATABASE_*` set; failed before harness start due to missing modules.
3. **No staging-host-verify JSON** — same Carton gap.
4. **No mail-check dry-run JSON** — same Carton gap.
5. **No Hypnotoad / stress-load smoke** — requires completed Carton + migrate/seed.
6. **No systemd evidence** — `--systemd` intentionally omitted on this VM.
7. **No live staging TLS / SMTP `--send` / representative hardware** — still required before any private-beta go decision.

## Explicit non-claim

**PRIVATE BETA: NOT YET.** Archiving this Cloud Agent VM complete-sequence
attempt (with Carton residual) does not change the release verdict.
