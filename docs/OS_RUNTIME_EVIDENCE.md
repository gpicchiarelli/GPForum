# GPForum OS Runtime Evidence

GPForum distinguishes OS-level performance posture from OS-level performance
evidence. A feature is not considered materially active just because an OS
profile declares support for it.

`GPForum::OS::RuntimeEvidence` is the benchmark evidence probe used by
`script/bench-hypnotoad`. It reports:

* declared event backend versus actual Mojolicious reactor class;
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

macOS and FreeBSD profiles declare `kqueue`; Linux declares `epoll`. The actual
Mojolicious reactor depends on installed Perl reactor modules. If no native
reactor module is available, Mojolicious may fall back to `Mojo::Reactor::Poll`.

`reuse=1` is portable at the GPForum policy layer only when the detected OS
supports `SO_REUSEPORT`. UNIX socket listen URLs intentionally do not receive
`reuse=1`.

Sendfile remains a reverse-proxy/web-server responsibility. GPForum should not
serve large static files or attachments through Perl controllers on the hot path.
