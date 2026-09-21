# Cloud Agent VM stress-load 500 / 1000 evidence

**Date:** 2026-09-20  
**Host:** Cursor Cloud Agent VM (Linux, 4 vCPU / ~15 GiB RAM)  
**Branch:** `cursor/cloud-agent-stress500-aeb6`  
**Base commit:** `ef103e5`  
**Extends:** [`../2026-09-20-cloud-agent-live/`](../2026-09-20-cloud-agent-live/)  
**Verdict:** **PRIVATE BETA NOT YET** — live Hypnotoad stress profiles
`500` (`ok` / `--check` `pass`) and `1000` (`ok`; `--check` p95 residual)
archived; staging TLS / SMTP `--send` / systemd install / representative
multicore staging remain open.

This archive records a **completed** Carton install (`carton_ok`), migrate +
query-budget sync, medium seed, Hypnotoad on `:8080`, and
`script/stress-load` capacity profiles **500** and **1000**. Secrets lived
only in `/tmp/gpforum.env` (mode `0600`, not committed). It does **not**
claim private-beta readiness.

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
| Stress-load | **profile 500** `ok` + `--check` `pass`; **profile 1000** `ok` (p95 residual under `--check`) |

## Phase results

| Phase | Status | Artifact |
| --- | --- | --- |
| `script/gpforum-system-perl --preflight` | **pass** | `system-perl-preflight.txt` |
| `script/bootstrap-deps --postgres --rebuild-local` | **pass** | `bootstrap-deps.log.tail.txt`, `carton-status.txt` |
| `bin/gpforum-migrate --apply` | **pass** | `migrate.log` |
| `script/query-budget --sync` / `--check` | **pass** | `query-budget-sync.log`, `query-budget-check.log` |
| Hypnotoad `:8080` | **up** | `gpforum-hypnotoad-app.pl`, `hypnotoad.stderr`, `health-live.txt`, `health-ready.txt` |
| `script/stress-load --json --profile 500 --base-url http://127.0.0.1:8080` | **ok** | `stress-load-500.json`, `.stderr`, `.exit` |
| `script/stress-load --json --check --profile 500 …` | **pass** | `stress-load-500-check.json`, `.exit` |
| `script/stress-load --json --profile 1000 --base-url http://127.0.0.1:8080` | **ok** | `stress-load-1000.json`, `.stderr`, `.exit` |
| `script/stress-load --json --check --profile 1000 …` | **fail\*** | `stress-load-1000-check.json`, `.exit` |

\*Profile `1000` sustained peak in-flight **1000** with **zero** HTTP errors;
`--check` failed solely because p95 exceeded the default `--p95-limit-ms 2000`
(see table). Treat as **attempted / latency residual** on 4 vCPU.

### Stress summary

Harness: `script/stress-load --json` against `http://127.0.0.1:8080` with
elevated `GPFORUM_FORUM_READ_RATE_LIMIT=100000`. Primary rows below are the
non-`--check` archive JSON (`status=ok`).

| Profile | Status | Peak in-flight | Completed | Errors | Err % | req/s | p50 ms | p95 ms | p99 ms | max ms | Wall s |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `500` | ok | 500 | 5 000 | 0 | 0.000 | 573.594 | 851.762 | 1621.145 | 2384.845 | 2686.178 | 8.717 |
| `500` (`--check`) | pass | 500 | 5 000 | 0 | 0.000 | 589.553 | 971.871 | 1394.120 | 1880.514 | 2393.851 | 8.481 |
| `1000` | ok | 1000 | 10 000 | 0 | 0.000 | 576.663 | 1678.325 | 2478.208 | 2823.726 | 3304.456 | 17.341 |
| `1000` (`--check`) | fail\* | 1000 | 10 000 | 0 | 0.000 | 578.768 | 1695.937 | 2121.943 | 2634.636 | 3171.899 | 17.278 |

`/health/live` remained `200`/`ok` after the capacity window. `/health/ready`
may report overall `degraded` solely due to `shared_cache` `local-fallback`
(no GlifiStore on this VM).

## residual_gaps

1. **No staging TLS front door** — runs used `http://127.0.0.1:8080`, not a
   public staging hostname with TLS termination.
2. **No systemd unit install / `--systemd` probe** — intentionally omitted on
   this Cloud Agent VM.
3. **No SMTP `--send`** — mail-check not re-run in this archive.
4. **Profile `1000` p95 residual** under default `--check` thresholds on this
   4-vCPU VM (zero HTTP errors; peak in-flight 1000 sustained).
5. **Shared cache degraded** — local-fallback without GlifiStore.
6. **Representative multicore staging hardware** — still required before any
   private-beta go decision.

## Explicit non-claim

**PRIVATE BETA: NOT YET.** Completing Carton, archiving Hypnotoad stress
profiles `500`/`1000` on this Cloud Agent VM does not change the release
verdict.
