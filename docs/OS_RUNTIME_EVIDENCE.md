# GPForum OS Runtime Evidence

GPForum distinguishes OS-level performance posture from OS-level performance
evidence. A feature is not considered materially active just because an OS
profile declares support for it.

`GPForum::OS::RuntimeEvidence` is the benchmark evidence probe used by
`script/bench-hypnotoad`. It reports:

* declared event backend versus actual Mojolicious reactor class;
* native reactor dependency status for `Mojo::Reactor::EV`, `EV` and
  `IO::KQueue`;
* Hypnotoad worker, listen, backlog, keep-alive and graceful-timeout settings;
* whether `reuse=1` is present in the effective listen URL;
* kernel-level socket option probes for `SO_REUSEADDR`, `SO_REUSEPORT`,
  `SO_KEEPALIVE` and `TCP_NODELAY`;
* whether static transfer is merely delegated or actually materialized by the
  benchmark;
* PostgreSQL current server settings from `pg_settings` when a database is
  available;
* temporary filesystem path, `df` output and mount type.

## Current macOS Finding

On the current macOS/Postgres.app development machine:

| Capability | Status | Evidence |
| --- | --- | --- |
| Hypnotoad prefork | active | benchmark starts Hypnotoad and records master/worker PIDs |
| `SO_REUSEPORT` listen config | active | listen URL contains `reuse=1` |
| `SO_REUSEPORT` kernel support | active | socket probe can set and read the option |
| `SO_KEEPALIVE` | active | socket probe can set and read the option |
| `TCP_NODELAY` | active | socket probe can set and read the option |
| file descriptor limit | active | preflight reports `1048575` |
| declared macOS backend | configurable | OS profile declares `kqueue` |
| actual Mojolicious reactor | mismatch | runtime currently uses `Mojo::Reactor::Poll` |
| Mojolicious EV reactor module | configurable | `Mojo::Reactor::EV` is present in Mojolicious |
| native EV dependency | unavailable | `EV.pm` is not installed in the Carton environment |
| sendfile/X-Sendfile | configurable only | delegated posture exists; benchmark does not transfer files with sendfile |
| PostgreSQL tuning | configurable only | settings are read; GPForum does not mutate server tuning |
| temp filesystem | active | benchmark temp files are under APFS `/System/Volumes/Data` |

## Classification Rules

| Class | Meaning |
| --- | --- |
| active | the benchmark observed the behavior directly |
| configurable | GPForum can configure or delegate the behavior, but the benchmark did not materialize it |
| mismatch | declared posture and runtime observation differ |
| unavailable | runtime could not observe the capability |
| not implemented | the project has no implementation path yet |

## PostgreSQL Settings Captured

When a database is available, the evidence probe records current values for:

* `shared_buffers`
* `work_mem`
* `maintenance_work_mem`
* `effective_cache_size`
* `checkpoint_timeout`
* `checkpoint_completion_target`
* `max_wal_size`
* `min_wal_size`
* `wal_buffers`
* `max_connections`
* `synchronous_commit`
* `random_page_cost`
* `effective_io_concurrency`

These are server settings, not GPForum-enforced settings. GPForum reports them
so benchmark runs can be compared honestly across macOS, FreeBSD and Linux.

## Portability Notes

macOS and FreeBSD profiles declare a `kqueue` OS posture; Linux declares an
`epoll` OS posture. In Mojolicious, the practical efficient reactor path is
`Mojo::Reactor::EV` backed by the optional CPAN `EV` module. Without `EV`,
Mojolicious falls back to `Mojo::Reactor::Poll`.

GPForum does not make `EV` mandatory because it is an XS dependency and the
project must remain portable across macOS, FreeBSD and Linux. Production
operators who need high socket concurrency should explicitly test an
environment with `EV` installed and compare it with the Poll fallback using
`script/bench-hypnotoad-scaling`.

`reuse=1` is portable at the GPForum policy layer only when the detected OS
supports `SO_REUSEPORT`. UNIX socket listen URLs intentionally do not receive
`reuse=1`.

Sendfile remains a reverse-proxy/web-server responsibility. GPForum should not
serve large static files or attachments through Perl controllers on the hot path.

## Worker Scaling Evidence

`script/bench-hypnotoad-scaling` runs the same real forum/search route set
against multiple Hypnotoad worker counts. It is intended for local or nightly
evidence, not as a heavy CI default.

Example:

```sh
script/bench-hypnotoad-scaling --seed --check --profile hot-thread \
  --worker-set 2,4,8 --iterations 20 --warmup 3 \
  --route /categories \
  --route /c/018f1001-0001-7000-8000-000000000001 \
  --route /t/018f1004-0001-7000-8000-000000000001 \
  --route '/search?q=performance'
```

The default route set intentionally measures real SSR forum and search paths,
not only `/health/live`.
