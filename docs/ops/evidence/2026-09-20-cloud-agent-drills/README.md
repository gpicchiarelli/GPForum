# Cloud Agent VM drills evidence (Carton complete)

**Date:** 2026-09-20  
**Host:** Cursor Cloud Agent VM (Linux)  
**Branch:** `cursor/cloud-agent-drills-pass`  
**Extends:** [`../2026-09-20-cloud-agent-complete/`](../2026-09-20-cloud-agent-complete/) (PR #29 archived an intentional mid-install cut)  
**Verdict:** **PRIVATE BETA NOT YET** — Carton finished and drills ran; live staging TLS / SMTP `--send` / systemd install / representative hardware remain open.

This archive records a **completed** Carton install (`carton_ok`) followed by real
operator drills with non-skipped JSON (`pass` / `ok` / `degraded` where
applicable). It does not claim private-beta readiness.

## Environment notes

| Item | Result |
| --- | --- |
| System Perl | `/usr/bin/perl` 5.38.2 — PASS (`system-perl-preflight.txt`) |
| Carton (apt) | Installed (`carton` 1.0.35) |
| `script/bootstrap-deps --postgres --rebuild-local` | **PASS** — `BOOTSTRAP_EXIT:0`; 158 distributions (`bootstrap-deps.log.tail.txt`) |
| `carton_ok` (`Const::Fast` + `Mojo::Base`) | **PASS** (`carton-status.txt`) |
| PostgreSQL 16 | Cluster accepting on `127.0.0.1:5432`; role/DB `gpforum` (CREATEDB) |
| nginx | Installed (`nginx/1.24.0`); used by attachments deploy host validation |
| Hypnotoad on `:8080` | **Started** for optional stress smoke (wrapper `gpforum-hypnotoad-app.pl`) |
| Stress-load | **smoke** profile against live Hypnotoad — `ok` |

## Phase results

| Phase | Status | Artifact |
| --- | --- | --- |
| `script/gpforum-system-perl --preflight` | **pass** | `system-perl-preflight.txt` |
| `script/bootstrap-deps --postgres --rebuild-local` | **pass** | `bootstrap-deps.log.tail.txt`, `carton-status.txt` |
| `script/staging-host-verify --json` | **pass** (repo artifacts; live `--env-file` / `--systemd` / `--base-url` skipped) | `staging-host-verify.json`, `.stderr`, `.exit` |
| `script/staging-drill-attachments --json` | **pass** | `staging-drill-attachments.json`, `.stderr`, `.exit` |
| `script/staging-drill --json` (DSN set) | **pass** | `staging-drill.json`, `.stderr`, `.exit` |
| `script/gpforum-mail-check --json --dry-run` | **pass** | `gpforum-mail-check-dry.json`, `.stderr`, `.exit` |
| Hypnotoad `:8080` + `stress-load --profile smoke` | **ok** | `stress-load-smoke.json`, `health-live.txt`, `health-ready.txt`, `hypnotoad.stderr` |

### Drill status summary

| JSON | `status` |
| --- | --- |
| `staging-host-verify.json` | `pass` |
| `staging-drill-attachments.json` | `pass` |
| `staging-drill.json` | `pass` |
| `gpforum-mail-check-dry.json` | `pass` |
| `stress-load-smoke.json` | `ok` (20/20, error_rate 0) |

`/health/ready` reported overall `degraded` solely due to
`shared_cache` `local-fallback` (no Redis/shared cache on this VM); live and
other checks were `ok`.

## residual_gaps

1. **No live staging TLS / env-file / systemd activity** — `staging-host-verify` live flags not used on this VM.
2. **No SMTP `--send`** — mail-check dry-run only (`Email::Sender::Transport::Test`).
3. **No capacity profiles 100/500/1000** — only optional smoke against local Hypnotoad.
4. **No systemd unit install** — `--systemd` intentionally omitted; sample `systemd-analyze verify` / `nginx -t` covered inside attachments drill.
5. **Shared cache degraded** — local-fallback on Cloud Agent VM.
6. **Representative hardware / multicore staging evidence** — still required before any private-beta go decision.

## Explicit non-claim

**PRIVATE BETA: NOT YET.** Completing Carton and archiving pass/ok drill JSON on
this Cloud Agent VM does not change the release verdict. Co-author context:
previous PR #29 intentionally archived the incomplete Carton cut.
