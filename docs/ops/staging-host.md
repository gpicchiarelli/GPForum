# Staging host bring-up (live Hypnotoad + TLS)

Operator runbook for a long-lived **staging** host after the throwaway drills in
[`staging-drills.md`](staging-drills.md). Passing
`script/staging-host-verify` does **not** mean private-beta readiness. It only
checks that in-repo artifacts exist and, when you pass live flags, that the
env file has required **key names**, selected systemd units are active, and
HTTP health endpoints answer.

## Scope

| Step | What it proves | Tool |
| --- | --- | --- |
| Repo prerequisites | Deploy templates, carton wrapper, ops docs present | `script/staging-host-verify` (always) |
| Env file settings | every setting in `/etc/gpforum/gpforum.env` passes the checks the service makes at its start, the ones `gpforum doctor` reports, under the file's `GPFORUM_ENV` (else `production`, as the units set); each problem named, values never printed | `--env-file` |
| systemd units | `gpforum` / `gpforum-outbox` / `gpforum-scheduled-jobs.timer` report active | `--systemd` |
| Installed unit files | Deploy contract (User / EnvironmentFile / ExecStart) for web, outbox, scheduled-jobs | `--unit-dir` |
| Installed nginx site | Deploy contract (tcp or unix-socket template) | `--nginx-conf` |
| HTTP health | `/health/live`, `/health/ready` by HTTP code (optional `/metrics`) | `--base-url` |
| TLS observe | `https` scheme recorded (pair with health probe) | `--base-url https://…` |
| DB migrate / dump | Throwaway or staging DB path | `script/staging-drill` |
| Attachments + templates | Filesystem restore + static/host nginx/systemd samples | `script/staging-drill-attachments` |
| Mail | Transport dry-run / optional send | `script/mail-check` |
| Load | Concurrent HTTP profiles | `script/stress-load` |

## What this does not do

- Install or enable systemd units.
- Reload nginx or terminate TLS for you.
- Start Hypnotoad or write secrets.
- Claim private-beta or public production readiness.

## Bring-up sequence

Use a CI-green commit on `main`. On the staging host:

1. Checkout the commit; install deps with the OS system Perl
   (`make install-deps-production`). On macOS hosts,
   `eval "$(script/gpforum-homebrew-env)"` first.
2. Set the host up with `sudo gpforum setup --environment staging`, as
   [`../DEPLOYMENT.md`](../DEPLOYMENT.md#install-on-debian-or-ubuntu) step 3
   does: it makes the `gpforum` account, writes `/etc/gpforum/gpforum.env`
   (mode `0640`, owner root:`gpforum`) with its secrets, makes the database
   and applies the migrations. Answer its three questions with:
   - the staging host's own address: the template's
     `https://forum.example.com` is refused, and so is a sender at it
   - the database, or its data source when it is not on this host
   - the mail as [`mail-check.md`](mail-check.md) describes when testing
     identity mail; staging refuses `log`
3. Install `deploy/systemd/*.service` (and timer) and `deploy/nginx/*.conf`
   (or Caddy) with TLS as in [`../DEPLOYMENT.md`](../DEPLOYMENT.md).
4. Apply the migrations, the partition window and the query budgets as the
   `gpforum` user; `gpforum` reads the environment file itself
   ([`../DEPLOYMENT.md`](../DEPLOYMENT.md#install-on-debian-or-ubuntu), step 4):

```sh
sudo -u gpforum gpforum migrate
sudo -u gpforum gpforum budgets --check
```

5. Enable and start `gpforum` + `gpforum-outbox` (and scheduled jobs timer).
6. Reload nginx/Caddy; confirm TLS reaches Hypnotoad.

## Verify (non-destructive)

Repo-only (safe on a laptop, no staging required):

```sh
script/staging-host-verify --human
# or: make staging-host-verify
```

On the staging host after bring-up:

```sh
script/staging-host-verify --json \
  --env-file /etc/gpforum/gpforum.env \
  --unit-dir /etc/systemd/system \
  --nginx-conf /etc/nginx/sites-enabled/gpforum \
  --systemd \
  --base-url https://staging.example \
  --metrics-token "$GPFORUM_METRICS_TOKEN"
```

Prefer an `https://` `--base-url` so the TLS observe phase records the scheme
alongside the health probe. An `http://` base URL leaves TLS as a residual gap.
`--unit-dir` / `--nginx-conf` observe installed text against the shared deploy
contract (`GPForum::Service::Operations::DeployContract`); they do **not**
install, enable, or reload services.

Exit `0` for `pass` or `degraded`. `fail` means a probed phase failed (`1`);
misuse is `2`. An error the verify raises instead of reporting exits `1` too,
with the reason on standard error (an inline `password=` shown as
`[redacted]`) and JSON evidence of `check` `staging_host_verify`, `status`
`fail` and the reason in `error`.

## Evidence archive (private-beta blockers)

Paste JSON blobs (or paths) into the staging ops notes for that commit. Do not
commit secrets.

```sh
# 1) Host verify
script/staging-host-verify --json \
  --env-file /etc/gpforum/gpforum.env \
  --unit-dir /etc/systemd/system \
  --nginx-conf /etc/nginx/sites-enabled/gpforum \
  --systemd \
  --base-url "$STAGING_BASE_URL" \
  > /tmp/gpforum-staging-host-verify.json

# 2) DB migrate / upgrade / dump-restore (throwaway DBs OK if major version matches)
script/staging-drill --json > /tmp/gpforum-staging-drill.json

# 3) Attachments filesystem + deploy template/host sample checks
script/staging-drill-attachments --json > /tmp/gpforum-staging-drill-attachments.json

# 4) Mail dry-run (then optional --send to a mailbox you control)
script/mail-check --json --dry-run > /tmp/gpforum-mail-check-dry.json
# script/mail-check --json --send --to you@example.test

# 5) Stress profiles against the live staging URL
script/stress-load --json --profile smoke --base-url "$STAGING_BASE_URL" \
  > /tmp/gpforum-stress-smoke.json
script/stress-load --json --profile 100 --base-url "$STAGING_BASE_URL" \
  > /tmp/gpforum-stress-100.json
# then 500 / 1000 when the host is sized for them

# Or print the same live pack as one operator script (does not run anything):
script/gpforum-evidence-live --commands
# make evidence-live
```

Until those blobs exist for a staging target, readiness stays **PRIVATE BETA
NOT YET** even if every harness exits 0 locally.

## Residual gaps

- Live install/reload still operator-owned; this verify only observes.
- Attachment restore against a real `/srv/.../attachments` tree is still an
  operator drill beyond the throwaway `var/attachments` rehearsal.
- Staging/TLS stress numbers and SMTP `--send` evidence must be archived
  separately (see [`stress-load.md`](stress-load.md) and
  [`mail-check.md`](mail-check.md)). Prefer `https://` `--base-url` so the TLS
  observe phase is not left skipped.
