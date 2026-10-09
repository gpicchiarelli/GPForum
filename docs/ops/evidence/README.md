# Ops evidence archives

Operator-captured JSON/human blobs for private-beta *preparation*. Presence of
files here does **not** mean private beta is ready.

Validate candidates before/after archiving:

```sh
script/evidence-validate --human docs/ops/evidence/<archive>/*.json

# Stamp legacy archives with shared meta markers (stdout or --write):
script/evidence-meta --write docs/ops/evidence/<archive>/staging-host-verify.json
```

Harness-produced JSON already includes `secrets_redacted` /
`private_beta_claimed=0` via `EvidenceMeta` (verify, mail, stress, and staging
drills). Historical archives may be meta-stamped in place; measurements stay
unchanged. See [`../evidence-validate.md`](../evidence-validate.md).

| Archive | Notes |
| --- | --- |
| [2026-10-10-operator-walkthrough-3/](2026-10-10-operator-walkthrough-3/) | Operator ergonomics, iteration 3: the macOS quick start run through `gpforum setup` to a signed-in admin (12 steps, 3 questions answered with Enter, about 3 min 20 s in commands), a production host set up and its systemd, launchd and nginx files printed, the Debian install walked (15 typed commands from the clone against a target of 8, 3 questions, 2 documents, 14 steps), upgrade (3 lines) and metrics rotation (4 commands) followed from `gpforum help`, a backup taken and checked, and the friction left, ranked for iteration 4. Throwaway databases, dropped. |
| [2026-10-09-operator-walkthrough-2/](2026-10-09-operator-walkthrough-2/) | Operator ergonomics, iteration 2: the macOS quick start through `gpforum` run to a signed-in admin with a ready node and no psql (14 steps, 4 min 23 s), the Debian install walked (19 steps against a target of 15, 2 documents, 34 commands), `gpforum doctor` broken ten ways with each finding and fix quoted (10 of 10 named, 7 fixed to green here), and the friction left, ranked for iteration 3. Throwaway database, dropped. |
| [2026-10-08-operator-walkthrough-1/](2026-10-08-operator-walkthrough-1/) | Operator ergonomics, iteration 1: the macOS quick start run to a signed-in admin without an MTA (16 steps, about 6 minutes), the Debian install walked through its documents and code (22 steps, 2 documents, 34 commands, no undocumented step), every message met in English and Italian, and the friction left, ranked for iteration 2. Throwaway database, dropped. |
| [2026-10-07-operator-walkthrough/](2026-10-07-operator-walkthrough/) | Operator ergonomics, iteration 0: a fresh install walked as a new sysadmin (31 steps, 12 documents, 95 environment variables), the inventory of settings, commands and messages, the ranked proposal and the owner's decisions. Read only; no deployment. |
| [2026-09-20-cloud-agent-stress500/](2026-09-20-cloud-agent-stress500/) | Cloud Agent VM Hypnotoad `:8080` capacity: `carton_ok`, migrate + query-budget, medium seed, `stress-load` profile **500** `ok`/`--check` **pass**, profile **1000** `ok` (p95 residual under `--check`). Extends live archive. **PRIVATE BETA NOT YET.** |
| [2026-09-20-cloud-agent-live/](2026-09-20-cloud-agent-live/) | Cloud Agent VM live Hypnotoad `:8080`: `carton_ok`, migrate + query-budget, `staging-host-verify` `--env-file`/`--base-url` **pass**, `stress-load` profile **100** `ok` JSON. Extends drills archive. **PRIVATE BETA NOT YET.** |
| [2026-09-20-cloud-agent-drills/](2026-09-20-cloud-agent-drills/) | Cloud Agent VM after Carton completion: `carton_ok`, staging-host-verify / staging-drill / attachments / mail-check dry-run pass JSON, optional Hypnotoad stress smoke `ok`. Extends incomplete cut in `2026-09-20-cloud-agent-complete/`. **PRIVATE BETA NOT YET.** |
| [2026-09-20-cloud-agent-complete/](2026-09-20-cloud-agent-complete/) | Cloud Agent VM full-sequence attempt after PG/nginx apt + DB role; Carton incomplete — drills skipped; log tail + `residual_gaps`. **PRIVATE BETA NOT YET.** |
| [2026-09-20-cloud-agent/](2026-09-20-cloud-agent/) | Partial Cloud Agent VM prep; see README for pass/fail/skipped and `residual_gaps`. **PRIVATE BETA NOT YET.** |
| [2026-09-20-macos-laptop-prep/](2026-09-20-macos-laptop-prep/) | Developer Mac laptop prep; not a staging target. **PRIVATE BETA NOT YET.** |
