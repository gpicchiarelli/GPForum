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
| Known evidence families (`staging_host_verify`, `mail_delivery`, `stress-load`) | warn if unknown | fail if unknown |
| `residual_gaps` present | warn if missing | fail if missing |
| Mail `secrets_redacted` / `private_beta_claimed=0` | warn if missing | fail if missing |

Exit `0` for `pass` or `degraded`. `fail` is non-zero.

## Related

- [`staging-host.md`](staging-host.md)
- [`mail-check.md`](mail-check.md)
- [`stress-load.md`](stress-load.md)
- [`../evidence/README.md`](../evidence/README.md)
