# ADR 0125: The Environment Names Where a Node Runs, and the Host Sizes It

## Status

Accepted (2026-10-10). Implements operator iteration 4, "fewer settings":

- item D1' of the operator walkthrough
  (`docs/ops/evidence/2026-10-07-operator-walkthrough`, section 5.3), under
  owner decision D3;
- item D4' (the drill variables become flags);
- the deprecation path of section 5.6;
- friction 10 of walkthrough 3
  (`docs/ops/evidence/2026-10-10-operator-walkthrough-3`): the file setup
  writes is pruned to the settings a human decides.

It builds on ADR 0120 (the front door reads the environment file) and ADR
0122 (setup writes that file). It answers the owner's brief of 2026-10-10:
"Cancella tutto il superfluo".

## Context

`GPFORUM_ENV` said two things at once:

- **Where a node runs**: development, staging or production.
- **How big it is**: `production-small` or `production-medium`. `production`
  meant `production-small`.

The size had to be chosen by hand, and choosing it sized nothing. The
profile raised floors that the defaults did not meet. It also chose, without
saying so, how long the event log was kept: 365 days in small, 730 in
medium, 30 in development. Meanwhile the web processes were already sized
from the CPUs (`GPFORUM_WEB_PROCESSES=auto`). The cache was 4096 entries a
process on any host, a 512 MB VPS and a 64 GB server alike.

The file `gpforum setup` writes was the whole settings table: 258 lines, 10
of them set and 58 commented out. An operator who opened
`/etc/gpforum/gpforum.env` met every Hypnotoad timeout before the address of
their forum.

## Decision

### 1. Three environments

`GPFORUM_ENV` is `development`, `staging` or `production`. `test` stays as
the suite's own. A refusal lists only these:

```text
GPFORUM_ENV must be one of development, test, staging, production, not 'large'.
```

`GPForum::Service::Operations::Profile` holds one profile for each, version
2: what the environment requires (a rotated secret, restore evidence) and
the least a node may run at. The worker and realtime counts, which nothing
read, and the retention fields are gone from it.

### 2. The host sizes the node

- **Web processes**: `GPFORUM_WEB_PROCESSES=auto`, as before: two a CPU, at
  most 16.
- **The cache**: `GPFORUM_LOCAL_CACHE_MAX_ENTRIES=auto`, the new default.
  Each web process gets an equal part of an eighth of the host's memory, at
  about 16 KiB an entry. The result is rounded down to a power of two
  between 1024 and 16384. On a 1 GB host with one CPU that is 4096, the old
  default; on 16 GB with 8 CPUs, 8192. Memory that cannot be measured keeps
  4096.
- **The memory**: `GPForum::OS::Memory` reads it.
  - macOS: `sysctl hw.memsize`.
  - FreeBSD: `sysctl hw.physmem`.
  - Linux: `MemTotal`, held to a cgroup's `memory.max`, so a container is
    sized as the container.

A number set by hand is taken as it is. Each profile floor is the profile's,
or what the host is sized for when that is less, so a small host never
fails readiness on a setting nobody changed.

`gpforum doctor` says what the host sized the node for, under the settings
line. It names only the sizes that came from the host:

```text
✓ settings: production, read from /etc/gpforum/gpforum.env
✓ sized for 2 CPUs, 2 GB: 4 web processes, 4096 cache entries a process
```

In Italian:

```text
✓ dimensionato per 2 CPU, 2 GB: 4 processi web, 4096 voci di cache per processo
```

### 3. Retention is a setting

`GPFORUM_EVENT_RETENTION_DAYS` defaults to 365, production-small's value, in
every environment. It is how long the event log is kept before the
partitions job lists a monthly partition as due to detach. The job plans
over the lookahead the partition timer keeps (three months). The
notification retention the profiles carried was never read, and is gone.

### 4. Setup writes the decisions, and nothing else

`GPForum::Config::EnvironmentFile->render` is the file setup writes, 41
lines:

- five lines on what the file is and where every other setting is;
- the ten settings an installation decides, each under its one-line summary;
- commented out under the mail, the four SMTP settings, which are decisions
  only when mail leaves by smtp. A settings row says so with
  `operator_when => [ mail_transport => 'smtp' ]`.

`render_reference` is `deploy/gpforum.env.example`, every setting, as
before. The file setup writes names it for the rest.

### 5. Old names are read, and named, until v0.3.0

Each row of `@SETTINGS` has `aliases`. Each alias carries `read_until`
(`v0.3.0`) and is one of two kinds:

- **An old variable**, `{ env, values, refusal }`. `GPFORUM_SMTP_SSL`,
  which was `renamed_from`, is the first.
- **An old value**, `{ value, as }`. `GPFORUM_ENV=production-small` and
  `production-medium` are read as `production`.

What happens to an old name:

- **The start** logs one line with the line to write. An old value reads:

  ```text
  GPFORUM_ENV=production-medium is now called production; write GPFORUM_ENV=production in the environment file in its place.
  ```

  In Italian:

  ```text
  GPFORUM_ENV=production-medium ora si chiama production; scrivi GPFORUM_ENV=production nel file d'ambiente al suo posto.
  ```

- **`gpforum doctor`** lists the same line under `!`. Its fix is
  `set GPFORUM_ENV=production in /etc/gpforum/gpforum.env` for an old
  value. For an old variable it is two steps, the new line to write and
  the old one to remove: removed alone, `GPFORUM_SMTP_SSL=off` would leave
  TLS on. When the new variable is set too, only the old line goes.
- **Retired settings** (`GPFORUM_WORKER_PROCESSES`,
  `GPFORUM_REALTIME_PROCESSES`, `GPFORUM_OS_AFFINITY`) stay read and ignored
  as before, each with its warning.
- **`docs/DEPLOYMENT.md`, "Renamed settings"**, lists each old name, what
  replaces it and until when.
- **`t/615`** fails if an alias stops resolving, or outlives its release.

An install on `production-medium` keeps everything but its old retention
and floors. To keep its 730 days, set `GPFORUM_EVENT_RETENTION_DAYS=730`.
Its web floor of 8 meant nothing: the web processes were already sized
from the CPUs.

### 6. The drills take flags

The drills read their ports and directories from variables, where every
other command takes flags. They take flags now:

- `script/pitr-drill --port N --dir PATH`;
- `script/standby-drill --primary-port N --standby-port N --dir PATH`;
- `script/gpforum-evidence-live --out DIR --env-file PATH`.

The old variables (`GPFORUM_PITR_PORT`, `GPFORUM_PITR_DIR`,
`GPFORUM_STANDBY_PRIMARY_PORT`, `GPFORUM_STANDBY_PORT`,
`GPFORUM_STANDBY_DIR`, `GPFORUM_EVIDENCE_DIR`, `GPFORUM_EVIDENCE_ENV_FILE`)
are read until v0.3.0, each with one line on standard error:

```text
pitr-drill: GPFORUM_PITR_PORT is deprecated; use --port 55500
```

These scripts are maintainer tools (D9), so the line is English only.

A drill removes its working directory when it ends. `--dir` names a new or
empty directory: one that holds files is refused, before any cluster
starts, and left as it was. A relative `--dir` is taken from where the drill
was run, and made absolute, because PostgreSQL runs the archive and restore
commands from inside the data directory.

## Consequences

- **Fewer things to decide.** An operator chooses where a node runs. The
  size follows the host, and doctor shows it.
- **The cache can grow or shrink** with the host: 1024 entries a process on
  a 256 MB container, 16384 on a large server. A host that wants the old
  fixed size sets `GPFORUM_LOCAL_CACHE_MAX_ENTRIES=4096`.
- **The file setup writes is 41 lines.** A file written before this release
  keeps all its lines. Setup changes only the lines it sets.
- **The event retention and the partition horizon are the same everywhere.**
  Development keeps its events 365 days, where it kept 30.
- **`/health/ready`'s profile report changes.** It reads `production`,
  version 2, without the worker, realtime and retention fields.
- **`production-small` and `production-medium` stop working in v0.3.0.**
  Until then they start, and say so.

## Verification

- `t/610-environment-is-where-not-how-big.t`: the three environments, the
  refusal without the old names, the old names read as production, the
  start's line in English and Italian, and doctor's `!` with its fix.
- `t/611-sized-from-the-host.t`: memory read per system and held to a
  cgroup, the cache formula with its bounds, `auto` as the only word, what
  `sizing` reports, a small host meeting production's floors, and doctor's
  line in both languages.
- `t/612-setup-writes-the-decisions.t`: the file setup writes, its ten
  decisions, the SMTP lines, one summary each, the pointer to the
  reference, production accepting it filled in, and an smtp answer landing
  under mail.
- `t/613-event-retention-is-a-setting.t`: the setting, the settings page,
  and the partitions job reading it.
- `t/614-drills-take-flags.t`: the drills' flags, their usage errors, a
  `--dir` with files in it refused and kept, and each old variable's line.
- `t/615-every-alias-resolves.t`: every alias in the settings table resolves
  until its release, and each is in DEPLOYMENT's "Renamed settings".
