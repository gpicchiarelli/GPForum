# ADR 0124: The Service Reads Its Metrics Tokens Again From Its Environment File

## Status

Accepted (2026-10-10). This is the owner's decision for operator iteration 4:
a metrics-token rotation is three commands, `gpforum secret rotate metrics`,
the scrapers' new token, then `gpforum secret rotate metrics --finish`, and
the running service re-reads the accepted token list without a restart.
It amends ADR 0120 section 4, where `secret rotate` named a restart for
both secrets. The session secret keeps that restart. It builds on ADR 0120
(the front door reads the environment file, and the process environment
wins) and ADR 0121 (the application is built before Hypnotoad forks).

## Context

Walkthrough 3 (`docs/ops/evidence/2026-10-10-operator-walkthrough-3`,
section 4.2, friction 6) counted four commands for a rotation: rotate,
restart, `--finish`, restart. The target was three, straight from
`gpforum help`. The second restart is the one that makes the old token stop
working, so that restart was a security step and could not just be dropped.
The owner chose the other way out: the running service follows the file.

`GPFORUM_METRICS_TOKEN` and `GPFORUM_METRICS_TOKENS` decide two things, and
nothing else depends on them:

- whether `/metrics` answers, and
- whether `/health` and `/health/ready` give the full report or the status
  alone.

The values are compared per request, in constant time
(`GPForum::Web::OperationsAccess`). Changing the list while the service
runs is therefore safe, as long as it never changes to "no token", which
opens both endpoints in development.

## Decision

### 1. Where the list comes from

The tokens follow the environment file the service's supervisor read:

- **The file named in `GPFORUM_ENV_FILE`**, when the process environment
  holds it. This is how a service started for a file that is not the
  host's own names that file. The front door's `start --service`, which
  the printed units run, is to export the file it read before it execs
  Hypnotoad.
- **Otherwise, the file `bin/gpforum` read when Hypnotoad loaded it**
  (`GPForum::Command::Support::ServiceEnvironment->loaded`). That is the
  host's own: `/etc/gpforum/gpforum.env`, FreeBSD's
  `/usr/local/etc/gpforum/gpforum.env`, or Homebrew's on macOS, the file
  every shipped unit names. Installs that predate this release follow it
  with their current units.

### 2. Only a file that holds what the service started with

Whether the tokens follow the file is decided once
(`GPForum::Service::Operations::MetricsTokens->watch`, called from
`GPForum::Bootstrap::Operations`). It happens when the application is
built, before Hypnotoad forks, so every worker inherits the same decision,
including one Hypnotoad starts later to replace another.

The file is followed only when its tokens are exactly the ones the service
started with. The supervisor read that same file a moment earlier. If the
file holds others, it is not where the service's tokens came from: it may
belong to another forum on the same host, or the shell may have set the
token apart. In that case the tokens stay as they started, until a
restart, and the start logs why.

At start the process environment still wins, as ADR 0120 says. Once the
file is followed, its two lines win, which is the same precedence every
shipped supervisor applies on a restart:

- systemd's `EnvironmentFile=` overrides `Environment=`;
- the launchd job and the rc script source the file last.

### 3. When it is read again

Each token check (`/metrics`, `/health`, `/health/ready`) makes one `stat`
of the file. The file is read again only when one of these has changed:

- the device;
- the inode (`secret rotate` renames a new file into place);
- the mode;
- the size;
- the modification or change time, to the sub-second.

A read during which the file changed is not kept, and the next check reads
it again. Each Hypnotoad worker reads on its own and logs its own line.

### 4. What the service will not use, and never "none"

A changed file is not used, and the tokens it accepted before stay, when:

- it cannot be read, or it is gone;
- a line is not `NAME=value` (the front door's parser, read strictly);
- an account other than its owner may write it (`mode & 022`, the rule the
  FreeBSD rc scripts apply); a token chosen by another account would open
  `/metrics`;
- it names no `GPFORUM_METRICS_TOKEN`, or an empty one.

Each refusal is logged once, as a warning that names the file and the
reason and never a token. The file's signature is kept, so further checks
are silent until it changes again. The list never becomes "no token":
`/metrics` cannot open by accident. A successful re-read is logged at
`info`, with the number of tokens accepted.

### 5. The session secret is not read again

`GPFORUM_SESSION_SECRET` and `GPFORUM_SESSION_SECRETS` sign and verify
cookies. They are Mojolicious's `secrets`, which every worker sets at
start. Changing them in a running service would split the workers, some
signing with the new secret and some refusing it. `gpforum secret rotate
session` keeps its restart.

### 6. What `secret rotate metrics` prints

On a host whose service files are in place, when the file is the host's
own:

```text
$ sudo gpforum secret rotate metrics
✓ A new metrics token is in /etc/gpforum/gpforum.env. The one before stays in GPFORUM_METRICS_TOKENS, and the running service accepts both now, with no restart.
Next: give every scraper the new GPFORUM_METRICS_TOKEN from /etc/gpforum/gpforum.env, then gpforum secret rotate metrics --finish
$ sudo gpforum secret rotate metrics --finish
✓ The previous metrics tokens are gone from /etc/gpforum/gpforum.env, and the running service refuses them now, with no restart.
```

In Italian:

```text
✓ Un nuovo token delle metriche è in /etc/gpforum/gpforum.env. Quello precedente resta in GPFORUM_METRICS_TOKENS, e il servizio in esecuzione li accetta già entrambi, senza riavvio.
Prossimo passo: dai a ogni scraper il nuovo GPFORUM_METRICS_TOKEN da /etc/gpforum/gpforum.env, poi gpforum secret rotate metrics --finish
✓ I token delle metriche precedenti non sono più in /etc/gpforum/gpforum.env, e il servizio in esecuzione li rifiuta già, senza riavvio.
```

A file named with `--env-file` that is not the host's own keeps the
restart line, because the service is not known to follow it until its
units export `GPFORUM_ENV_FILE`. A host without service files keeps its
`service print` or `start --foreground` step. A session rotation is
unchanged.

## Consequences

- A metrics rotation is three commands, named one after another, with no
  restart. The token before stops working at the first check after
  `--finish`.
- Every token check costs one `stat` system call. Load-balancer probes of
  `/health/ready` pay it too.
- A service whose file is not the host's own, started without
  `GPFORUM_ENV_FILE`, keeps the tokens it started with, as before.
- `gpforum status` (ADR 0120's front door) reads the token from the file.
  Once the service follows the file, the two agree after a rotation with no
  restart.
- Someone who edits the file in place, in pieces, can make a scraper
  refused for the moment of the write. The read is never torn into "no
  token": a token cut short is refused, and nothing is opened.

## Verification

- `t/600-metrics-token-reload.t`:
  - `/metrics` and `/health/ready` through the application, across a
    rotation and its `--finish` with no restart;
  - one read for an unchanged file;
  - every refusal of section 4, logged once;
  - a file holding other tokens is not followed;
  - `GPFORUM_ENV_FILE` before the loaded file;
  - the session secret unchanged;
  - scrapes during 30 rotations, never refused and never opened;
  - a file written in place, in halves, never opening `/metrics`.

  Against the access code before this change, the rotation subtests fail.
- `t/601-secret-rotate-metrics-no-restart.t`: the three steps in English
  and Italian with no restart command, and the restart kept for a session
  secret and for a file that is not the host's own.
