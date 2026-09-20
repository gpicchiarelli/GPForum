# Cloud Agent VM live staging-host-verify + stress evidence (partial / interrupt)

**Date:** 2026-09-20  
**Host:** Cursor Cloud Agent VM (Linux)  
**Branch:** `cursor/cloud-agent-live-stress`  
**Extends:** [`../2026-09-20-cloud-agent-drills/`](../2026-09-20-cloud-agent-drills/) (`carton_ok` + smoke already archived)  
**Verdict:** **PRIVATE BETA NOT YET** — interrupt PR archives mid-bootstrap status; live `--env-file` / `--base-url` staging-host-verify and stress profiles 100/500 were **not** completed before cut.

This archive intentionally records a **partial** cut so operators can see progress
toward LIVE Hypnotoad verify + capacity profiles. It does **not** claim
private-beta readiness.

## Environment notes

| Item | Result |
| --- | --- |
| System Perl | `/usr/bin/perl` 5.38.2 — PASS (`system-perl-preflight.txt`) |
| Carton (apt) | Installed (`carton` 1.0.35) |
| `script/bootstrap-deps --postgres --rebuild-local` | **IN PROGRESS** at interrupt (~137 distributions; see `bootstrap-deps.log.tail.txt`) |
| `carton_ok` (`Const::Fast`) | **FAIL / not yet** (`carton-status.txt`) |
| PostgreSQL 16 | Accepting on `127.0.0.1:5432`; dedicated DB `gpforum_live_evidence` created (`postgres-status.txt`) |
| Throwaway env file | Planned at `/tmp/gpforum-evidence.env` (outside git) — **not written** before interrupt |
| Hypnotoad on `:8080` | **Not started** (blocked on Carton) |
| Live staging-host-verify | **Not run** |
| Stress-load smoke / 100 / 500 | **Not run** |

## Phase results

| Phase | Status | Artifact |
| --- | --- | --- |
| `script/gpforum-system-perl --preflight` | **pass** | `system-perl-preflight.txt` |
| PostgreSQL up + dedicated DB | **pass** (prep only) | `postgres-status.txt` |
| `script/bootstrap-deps --postgres --rebuild-local` | **in_progress** | `bootstrap-deps.log.tail.txt`, `carton-status.txt` |
| `script/staging-host-verify --json --env-file … --base-url …` | **skipped** (Carton incomplete) | — |
| `script/stress-load --json --profile smoke` | **skipped** | — |
| `script/stress-load --json --profile 100` | **skipped** | — |
| `script/stress-load --json --profile 500` | **skipped** | — |

### Drill status summary

| JSON | `status` |
| --- | --- |
| `staging-host-verify.json` | **not captured** (LIVE intended; blocked) |
| `stress-load-smoke.json` | **not captured** |
| `stress-load-100.json` | **not captured** |
| `stress-load-500.json` | **not captured** |

Prior completed drills (repo-only verify + smoke) remain under
[`../2026-09-20-cloud-agent-drills/`](../2026-09-20-cloud-agent-drills/).

## residual_gaps

1. **Carton incomplete** — `carton_ok` false; wait for `BOOTSTRAP_EXIT:0` then re-probe `Const::Fast`.
2. **No LIVE staging-host-verify** — need `--env-file` (keys only; secrets outside git) + `--base-url http://127.0.0.1:8080` against Hypnotoad; TLS still open.
3. **No stress-load profiles smoke / 100 / 500** — blocked on Hypnotoad; raise `GPFORUM_FORUM_READ_RATE_LIMIT` for capacity runs.
4. **No migrate / query-budget sync on dedicated DB** — deferred until Carton finishes.
5. **No SMTP `--send`** — still open (mail-check dry-run only in prior archives).
6. **No systemd unit install** — `--systemd` / live unit install still open.
7. **Shared cache / representative hardware** — still required before any private-beta go decision.

## Explicit non-claim

**PRIVATE BETA: NOT YET.** This interrupt archive does not change the release
verdict. Follow-up should finish Carton, start Hypnotoad, archive LIVE
staging-host-verify JSON and stress profiles under this directory (or a dated
successor), then update the evidence index without claiming readiness.
