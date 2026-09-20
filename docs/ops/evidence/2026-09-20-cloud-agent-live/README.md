# Cloud Agent VM live verify evidence (Hypnotoad + stress 100)

**Date:** 2026-09-20  
**Host:** Cursor Cloud Agent VM (Linux)  
**Branch:** `cursor/cloud-agent-live-verify-baaa`  
**Checkout base:** `e5bc023` (main tip when the Cloud Agent started)  
**Evidence revision:** `e964899` (same commit that archives this tree and fixes
`StagingHostVerify` metrics header to `X-GPForum-Metrics-Token`)  
**Merged on main:** `ef103e5`  
**Extends:** [`../2026-09-20-cloud-agent-drills/`](../2026-09-20-cloud-agent-drills/)  
**Verdict:** **PRIVATE BETA NOT YET** — live local Hypnotoad verify + stress
profile `100` archived; staging TLS / SMTP `--send` / systemd install /
representative multicore staging remain open.

This archive records a **completed** Carton install (`carton_ok`), migrate +
query-budget sync, Hypnotoad on `:8080`, `staging-host-verify` with
`--env-file` + `--base-url` (metrics included), and `stress-load --profile 100`
JSON. Secrets lived only in `/tmp/gpforum.env` (not committed). It does **not**
claim private-beta readiness.

**Reproducibility note:** `e5bc023` alone still used the wrong `X-Metrics-Token`
scrape header. The authenticated `/metrics` pass in `staging-host-verify.json`
was produced only after the in-tree header patch that landed in `e964899`
together with this archive — reproduce from that revision (or later `main`),
not from bare `e5bc023`.

## Environment notes

| Item | Result |
| --- | --- |
| System Perl | `/usr/bin/perl` 5.38.2 — PASS (`system-perl-preflight.txt`) |
| Carton (apt) | Installed (`carton` 1.0.35) |
| `script/bootstrap-deps --postgres --rebuild-local` | **PASS** — `BOOTSTRAP_EXIT:0`; 158 distributions (`bootstrap-deps.log.tail.txt`) |
| `carton_ok` (`Const::Fast` + `Mojo::Base`) | **PASS** (`carton-status.txt`) |
| PostgreSQL 16 | Cluster accepting on `127.0.0.1:5432`; role/DB `gpforum` |
| nginx | Installed (`nginx/1.24.0`) |
| Env secrets | `/tmp/gpforum.env` (mode `0600`, not in git) with required keys |
| Migrate + query-budget | **PASS** (`migrate.log`, `query-budget-*.log`) |
| Seed | `medium` (`seed.log`) |
| Hypnotoad on `:8080` | **Started** (`GPFORUM_WEB_PROCESSES=4`, elevated `GPFORUM_FORUM_READ_RATE_LIMIT=100000`) |
| Stress-load | **profile 100** against live Hypnotoad — `ok` |

## Phase results

| Phase | Status | Artifact |
| --- | --- | --- |
| `script/gpforum-system-perl --preflight` | **pass** | `system-perl-preflight.txt` |
| `script/bootstrap-deps --postgres --rebuild-local` | **pass** | `bootstrap-deps.log.tail.txt`, `carton-status.txt` |
| `bin/gpforum-migrate --apply` | **pass** | `migrate.log` |
| `script/query-budget --sync` / `--check` | **pass** | `query-budget-sync.log`, `query-budget-check.log` |
| Hypnotoad `:8080` | **up** | `gpforum-hypnotoad-app.pl`, `hypnotoad.stderr`, `health-live.txt`, `health-ready.txt` |
| `script/staging-host-verify --json --env-file /tmp/gpforum.env --base-url http://127.0.0.1:8080` | **pass** (systemd skipped) | `staging-host-verify.json`, `.stderr`, `.exit` |
| `script/stress-load --json --profile 100 --base-url http://127.0.0.1:8080` | **ok** | `stress-load-100.json`, `.stderr`, `.exit` |

### Drill status summary

| JSON | `status` |
| --- | --- |
| `staging-host-verify.json` | `pass` |
| `stress-load-100.json` | `ok` (1000/1000, error_rate 0.000, peak_inflight 100, ~522 req/s, p95 ~442 ms) |

`/health/ready` reported overall `degraded` solely due to `shared_cache`
`local-fallback` (no GlifiStore on this VM); live and other checks were `ok`.
`staging-host-verify` health probes (`/health/live`, `/health/ready`,
`/metrics` via `X-GPForum-Metrics-Token`) all **pass**.

Harness note: `StagingHostVerify` metrics probe header corrected to
`X-GPForum-Metrics-Token` (was `X-Metrics-Token`).

## residual_gaps

1. **No staging TLS front door** — verify used `http://127.0.0.1:8080`, not a
   public staging hostname with TLS termination.
2. **No systemd unit install / `--systemd` probe** — intentionally omitted on
   this Cloud Agent VM.
3. **No SMTP `--send`** — mail-check not re-run in this archive.
4. **No capacity profiles 500/1000** — only profile `100` in this cut
   (prior VM appendix already has elevated 500/1000 rows elsewhere).
5. **Shared cache degraded** — local-fallback without GlifiStore.
6. **Representative multicore staging hardware** — still required before any
   private-beta go decision.

## Explicit non-claim

**PRIVATE BETA: NOT YET.** Completing Carton, archiving live
`staging-host-verify` pass JSON with `--env-file`/`--base-url`, and
`stress-load` profile `100` `ok` on this Cloud Agent VM does not change the
release verdict.
