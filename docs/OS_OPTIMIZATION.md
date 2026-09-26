# GPForum OS Optimization

GPForum treats OS-level performance as an operational contract, not as hidden
magic. The application detects and reports the runtime posture for macOS,
FreeBSD, Linux, and unknown Unix-like systems. It does not change sysctl values,
raise limits, require root, or apply host tuning implicitly.

## Preflight

Run the diagnostic preflight locally:

```sh
script/os-preflight
script/os-preflight --json
script/os-preflight --strict
```

The preflight reports:

- detected OS profile: `darwin`, `freebsd`, `linux`, or `unknown`;
- expected event backend: `kqueue`, `epoll`, or conservative `select`;
- CPU count and recommended web worker count;
- configured web, worker, and realtime process counts;
- open file descriptors and file descriptor limit where detectable;
- effective `reuseport`, `sendfile`, `static_xsendfile`, worker priority, and
  affinity settings;
- socket posture for `SO_REUSEADDR`, `SO_REUSEPORT`, `SO_KEEPALIVE`,
  `TCP_NODELAY`, and delegated `sendfile`;
- process-class nice plan for web, projection, search, mail, and maintenance
  workers.

Default exit behavior fails only on `fail`. `--strict` also fails on
`degraded`, which is useful for production deployment checks.

## Event Backends

Linux profiles declare `epoll`. macOS and FreeBSD profiles declare `kqueue`.
Unknown systems fall back to `select` and are marked degraded because the
platform has not been given an explicit performance contract.

This is diagnostic information for GPForum and its operators. Mojolicious and
Hypnotoad still own the actual event loop implementation.

## Socket Policy

GPForum centralizes socket policy in `GPForum::OS::Socket`.

- `SO_REUSEADDR` is expected for listener restart tolerance.
- `SO_REUSEPORT` is enabled only when supported or explicitly requested on a
  supported platform.
- `SO_KEEPALIVE` is expected for connection liveness.
- `TCP_NODELAY` is expected for latency-sensitive dynamic responses.
- `sendfile` is treated as a delegated transfer capability, usually handled by
  a reverse proxy or web server.

If an operator explicitly sets a feature to `on` on an unsupported platform,
preflight reports `degraded`. If the feature is `auto`, unsupported platforms
stay conservative.

## Feature Flags

Environment variables:

- `GPFORUM_OS_REUSEPORT=auto|on|off`
- `GPFORUM_OS_SENDFILE=auto|on|off`
- `GPFORUM_OS_STATIC_XSENDFILE=auto|on|off`
- `GPFORUM_OS_WORKER_PRIORITY=auto|on|off`
- `GPFORUM_OS_AFFINITY=off|manual`
- `GPFORUM_OS_MIN_RECOMMENDED_WORKERS=<integer>`
- `GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS=<integer>`

Defaults are production-oriented but still conservative. The default nofile
floor is `65536`; lower host limits should be treated as deployment drift.
Affinity is never applied by the application; it is a deployment-level
declaration.

## Worker Priority

The process priority model is descriptive unless worker priority is explicitly
enabled:

| class | nice delta |
| --- | ---: |
| `web_worker` | 0 |
| `projection_worker` | 5 |
| `search_worker` | 5 |
| `mail_worker` | 8 |
| `maintenance_worker` | 10 |

GPForum reports the intended plan. Process supervisors such as Hypnotoad,
systemd, rc.d, launchd, jails, or deployment scripts remain responsible for
actual process management.

## File Descriptors

Preflight reports current open file descriptors from `/proc/$pid/fd` or
`/dev/fd` where available. It reports the file descriptor limit through
portable `sysconf(_SC_OPEN_MAX)` when the platform exposes it.

Low limits are deployment warnings because they affect concurrent sockets,
database connections, logs, static assets, uploads, and worker pipes.
Production preflight expects `LimitNOFILE=65536` or an equivalent OS limit.

## Static Files And Attachments

Large static assets and attachments should be transferred by a reverse proxy or
web server with cache headers and sendfile support where available. GPForum may
authorize access, but Perl controllers should not become the ordinary path for
large file transfer.

## What GPForum Applies Now

Current GPForum behavior:

- detects OS profile once through `GPForum::OS`;
- exposes OS posture through `/metrics`;
- checks OS posture through readiness and platform checks;
- provides `script/os-preflight` for human and JSON diagnostics;
- configures Hypnotoad workers, backlog, keep-alive, graceful shutdown, and
  supported reuseport listen URLs through `GPForum::OS::RuntimePolicy`;
- reports degradation when requested OS features are unsupported;
- reports conservative warnings for excessive web worker counts and low file
  descriptor limits.

Current GPForum behavior deliberately does not:

- modify sysctl values;
- raise file descriptor limits;
- require root;
- pin CPU affinity;
- install or modify systemd, rc.d, or launchd units automatically;
- patch kernel socket behavior outside the Mojolicious/Hypnotoad runtime.

See also [OS_RUNTIME_ENFORCEMENT.md](OS_RUNTIME_ENFORCEMENT.md) and
[DEPLOYMENT.md](DEPLOYMENT.md).

## Supervisor Boundary

Deployment supervisors remain responsible for:

- Hypnotoad prefork process count;
- systemd unit hardening on Linux;
- rc.d scripts and jails on FreeBSD;
- launchd or local development setup on macOS;
- reverse proxy TLS, compression, buffering, and static transfer;
- OS-level file descriptor limits and kernel tuning.

GPForum's responsibility is to make the expected posture explicit,
machine-readable, testable, and observable.
