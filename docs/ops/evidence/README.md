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
| [2026-09-20-cloud-agent-stress500/](2026-09-20-cloud-agent-stress500/) | Cloud Agent VM Hypnotoad `:8080` capacity: `carton_ok`, migrate + query-budget, medium seed, `stress-load` profile **500** `ok`/`--check` **pass**, profile **1000** `ok` (p95 residual under `--check`). Extends live archive. **PRIVATE BETA NOT YET.** |
| [2026-09-20-cloud-agent-live/](2026-09-20-cloud-agent-live/) | Cloud Agent VM live Hypnotoad `:8080`: `carton_ok`, migrate + query-budget, `staging-host-verify` `--env-file`/`--base-url` **pass**, `stress-load` profile **100** `ok` JSON. Extends drills archive. **PRIVATE BETA NOT YET.** |
| [2026-09-20-cloud-agent-drills/](2026-09-20-cloud-agent-drills/) | Cloud Agent VM after Carton completion: `carton_ok`, staging-host-verify / staging-drill / attachments / mail-check dry-run pass JSON, optional Hypnotoad stress smoke `ok`. Extends incomplete cut in `2026-09-20-cloud-agent-complete/`. **PRIVATE BETA NOT YET.** |
| [2026-09-20-cloud-agent-complete/](2026-09-20-cloud-agent-complete/) | Cloud Agent VM full-sequence attempt after PG/nginx apt + DB role; Carton incomplete — drills skipped; log tail + `residual_gaps`. **PRIVATE BETA NOT YET.** |
| [2026-09-20-cloud-agent/](2026-09-20-cloud-agent/) | Partial Cloud Agent VM prep; see README for pass/fail/skipped and `residual_gaps`. **PRIVATE BETA NOT YET.** |
| [2026-09-20-macos-laptop-prep/](2026-09-20-macos-laptop-prep/) | Developer Mac laptop prep; not a staging target. **PRIVATE BETA NOT YET.** |
