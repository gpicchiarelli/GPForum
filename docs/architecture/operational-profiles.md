# Operational Profiles

`GPForum::Service::Operations::Profile` versions explicit runtime floors for:

- `development`
- `staging`
- `production-small`
- `production-medium`

`GPFORUM_ENV=production` maps to `production-small`. `test` maps to
`development`. Profiles are floors: a host may run more processes than the
selected profile, but not fewer.

Each profile also records partition horizon and retention days consumed by
`GPForum::Service::Operations::PartitionLifecycle`. Sample values live in
`etc/development.conf`, `etc/staging.conf`, `etc/production-small.conf`, and
`etc/production-medium.conf`. Session secrets for staging and production
profiles must not use the development default. Previous secrets may be
listed in `GPFORUM_SESSION_SECRETS` so existing cookies still validate
after rotation; staging and production reject the development default in
that list as well. Staging and production
profiles also require `GPFORUM_GLIFISTORE_URL` for the disposable shared L2
cache. Development defaults to `tcp://127.0.0.1:7379`. PostgreSQL remains
authoritative; GlifiStore is never a second source of truth.

Coverage lives in `t/98-operational-profiles.t`, `t/01-config.t`,
`t/33-health-readiness.t`, and `t/39-platform-check-command.t`.
`bin/gpforum-platform-check` and `/health/ready` both evaluate the selected
profile against the running config.
