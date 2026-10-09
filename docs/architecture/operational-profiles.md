# Operational Profiles

`GPForum::Service::Operations::Profile` versions explicit runtime floors for:

- `development`
- `staging`
- `production-small`
- `production-medium`

`GPFORUM_ENV=production` maps to `production-small`. `test` maps to
`development`. Profiles are floors: a host may run more processes than the
selected profile, but not fewer. The web process floor is the profile's, or
what the host's CPUs carry when that is less, and the local cache floor of
every profile is at most `GPFORUM_LOCAL_CACHE_MAX_ENTRIES`'s default (4096),
so no profile fails readiness on a setting nobody changed.

Each profile also records partition horizon and retention days consumed by
`GPForum::Service::Operations::PartitionLifecycle`. The values are the
`%PROFILES` constant in `GPForum::Service::Operations::Profile`; there are no
profile files. `etc/development.conf`, `etc/staging.conf`,
`etc/production-small.conf` and `etc/production-medium.conf` used to sit here
and looked authoritative, but nothing ever opened them: an operator editing
one got silence. They were removed rather than wired up, because the
environment is already the configuration mechanism and a second one with
undocumented precedence is worse than none. The environment file is that mechanism, not
a second one: systemd's `EnvironmentFile=` and the FreeBSD rc script read it
into the service, and `gpforum`, the front door, reads the same file for a
command typed by hand (ADR 0120). Its precedence is documented there: the
process environment first, then `/etc/gpforum/gpforum.env` (or the file
given with `--env-file`), then GPForum's defaults. Session secrets for staging and production
profiles must not use the development default. Previous secrets may be
listed in `GPFORUM_SESSION_SECRETS` so existing cookies still validate
after rotation; staging and production reject the development default in
that list as well. No profile requires `GPFORUM_GLIFISTORE_URL`: it is empty
by default everywhere, and then each process keeps its own cache, which a
single host needs no more than; set it to share a disposable L2 cache between
hosts. PostgreSQL remains authoritative; GlifiStore is never a second source
of truth.

Coverage lives in `t/98-operational-profiles.t`, `t/01-config.t`,
`t/33-health-readiness.t`, and `t/39-platform-check-command.t`.
`bin/gpforum-platform-check` and `/health/ready` both evaluate the selected
profile against the running config.
