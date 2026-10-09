# Operational Profiles

`GPFORUM_ENV` says where a node runs: `development`, `staging` or
`production` (`test` is the suite's own and maps to `development`). It no
longer says how big the node is. `GPForum::Service::Operations::Profile`
(version 2, ADR 0125) holds what each environment requires:

| Profile | Rotated session secret | Restore evidence | Web process floor | Cache floor (entries a process) |
| --- | --- | --- | --- | --- |
| `development` | no | no | 1 | 256 |
| `staging` | yes | yes | 2 | 512 |
| `production` | yes | yes | 4 | 2048 |

## Size comes from the host

- **Web processes**: `GPFORUM_WEB_PROCESSES=auto` (the default) runs two a
  CPU, at most 16 (`GPForum::Config::automatic_web_processes`).
- **Each web process's cache**: `GPFORUM_LOCAL_CACHE_MAX_ENTRIES=auto` (the
  default) gives each web process an equal part of an eighth of the host's
  memory, at about 16 KiB an entry. The result is rounded down to a power of
  two between 1024 and 16384 (`automatic_local_cache_max_entries`). On a
  1 GB host with one CPU that is 4096, the old fixed default. Memory that
  cannot be measured keeps 4096. `GPForum::OS::Memory` reads the memory:
  - `sysctl hw.memsize` on macOS;
  - `sysctl hw.physmem` on FreeBSD;
  - `MemTotal` on Linux, held to a cgroup's `memory.max`.

Each floor is the profile's, or what the host is sized for when that is
less, so a small host never fails readiness on a setting nobody changed. A
number set by hand is taken as it is and held to the floor. `gpforum doctor`
says what the host sized the node for:

```text
✓ sized for 2 CPUs, 2 GB: 4 web processes, 4096 cache entries a process
```

## Retention is a setting

`GPFORUM_EVENT_RETENTION_DAYS` (365, production-small's value) is how long
the event log is kept. After that, the partitions job lists each monthly
partition as due to detach. The job plans partitions over the lookahead the
partition timer keeps (three months). Both values used to come with the
size profile.

## Old names

`production-small` and `production-medium` were size profiles. They are now
old names of `production`, read as it until v0.3.0. The start logs one line
for each, and `gpforum doctor` lists it under `!` with the line to write:

```text
! GPFORUM_ENV=production-medium is now called production; write GPFORUM_ENV=production in the environment file in its place.
    Fix: set GPFORUM_ENV=production in /etc/gpforum/gpforum.env
```

`production-medium` held the event log 730 days. To keep that, set
`GPFORUM_EVENT_RETENTION_DAYS=730`. Every renamed setting is in
`docs/DEPLOYMENT.md`, "Renamed settings".

## No profile files

There are no profile files: the values are the `%PROFILES` constant in
`GPForum::Service::Operations::Profile`. `etc/development.conf`,
`etc/staging.conf`, `etc/production-small.conf` and
`etc/production-medium.conf` used to sit here and looked authoritative, but
nothing ever opened them: an operator editing one got silence. They were
removed rather than wired up, because the environment is already the
configuration mechanism and a second one with undocumented precedence is
worse than none.

The environment file is that mechanism, not a second one:

- systemd's `EnvironmentFile=` and the FreeBSD rc script read it into the
  service;
- `gpforum`, the front door, reads the same file for a command typed by
  hand (ADR 0120).

Its precedence is documented there: the process environment first, then
`/etc/gpforum/gpforum.env` (or the file given with `--env-file`), then
GPForum's defaults. `gpforum setup` writes that file with the settings an
installation decides and nothing else. `deploy/gpforum.env.example` lists
every setting.

## Secrets and GlifiStore

- **Session secrets**: staging and production must not use the development
  default. Previous secrets may be listed in `GPFORUM_SESSION_SECRETS`, so
  existing cookies still validate after rotation. Staging and production
  reject the development default in that list as well.
- **GlifiStore**: no profile requires `GPFORUM_GLIFISTORE_URL`. It is empty
  by default everywhere, and then each process keeps its own cache, which a
  single host needs no more than. Set it to share a disposable L2 cache
  between hosts. PostgreSQL remains authoritative; GlifiStore is never a
  second source of truth.

## Coverage

- `t/98-operational-profiles.t`, `t/509-defaults-meet-every-profile.t`;
- `t/610-environment-is-where-not-how-big.t` for the three environments and
  the old names;
- `t/611-sized-from-the-host.t` for the size and doctor's line;
- `t/613-event-retention-is-a-setting.t` for retention;
- `t/01-config.t`, `t/33-health-readiness.t`, `t/39-platform-check-command.t`.

`bin/gpforum-platform-check` and `/health/ready` both evaluate the selected
profile against the running config.
