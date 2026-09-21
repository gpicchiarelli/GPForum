# Evidence archive validation

Validate operator-captured JSON under `docs/ops/evidence/` (or `/tmp`) before
treating it as private-beta *preparation* evidence.

**Passing validation does not mean private beta is ready.**

## Entrypoint

```sh
script/gpforum-evidence-validate --human \
  docs/ops/evidence/2026-09-20-cloud-agent-live/staging-host-verify.json \
  docs/ops/evidence/2026-09-20-cloud-agent-live/stress-load-100.json

script/gpforum-evidence-validate --strict --json /tmp/gpforum-evidence-live/*.json
# or: make evidence-validate FILES='a.json b.json'
```

## What it checks

| Rule | Default | `--strict` |
| --- | --- | --- |
| JSON object decode | fail | fail |
| Obvious secret keys/patterns | fail | fail |
| Private-beta readiness claims in text | fail | fail |
| Known evidence families (`staging_host_verify`, `mail_delivery`, `stress-load`, `staging_drill`, `attachment_filesystem`, `deploy_checklist`, `staging_ops_extensions`, `dead_letter_check`, `mail_lifecycle_check`) | warn if unknown | fail if unknown |
| `residual_gaps` present | warn if missing | fail if missing |
| Shared meta (`secrets_redacted`, `private_beta_claimed=0`) on all known families | warn if missing | fail if missing |

Harnesses (`staging-host-verify`, `mail-check`, `stress-load`, staging drills)
emit that meta via `GPForum::Service::Operations::EvidenceMeta`. Older archives
without the markers validate as `degraded` (or `fail` under `--strict`).
Re-stamp with:

```sh
script/gpforum-evidence-meta --write path/to/archive.json
```

Exit `0` for `pass` or `degraded`. `fail` is non-zero.

## Related

- [`staging-host.md`](staging-host.md)
- [`mail-check.md`](mail-check.md)
- [`stress-load.md`](stress-load.md)
- [`evidence/README.md`](evidence/README.md)
