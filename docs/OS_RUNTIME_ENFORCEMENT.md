# GPForum OS Runtime Enforcement

This document records the step from descriptive OS posture to runtime behavior
that GPForum can verify.

## Runtime Contract

GPForum now builds a Hypnotoad runtime configuration during Mojolicious
startup through `GPForum::OS::RuntimePolicy`.

Applied directly to the application:

- `listen`
- `workers`
- `spare`
- `clients`
- `backlog`
- `requests`
- `keep_alive_timeout`
- `inactivity_timeout`
- `graceful_timeout`
- `heartbeat_interval`
- `heartbeat_timeout`
- `upgrade_timeout`
- `proxy`
- `pid_file`

The application also stores the runtime enforcement report in
`gpforum_runtime_enforcement` and exposes it through metrics.

## Worker Enforcement

Default policy:

```text
GPFORUM_RUNTIME_WORKER_POLICY=cap-to-cpu
GPFORUM_RUNTIME_MAX_WEB_PER_CPU=2
```

If `GPFORUM_WEB_PROCESSES` exceeds `cpu_count * max_web_per_cpu`, Hypnotoad is
configured with the capped value and the runtime enforcement report becomes
`degraded`. Operators can choose `configured` to preserve an explicit worker
count, but the preflight remains responsible for warning about oversubscription.

## Socket Enforcement

`SO_REUSEPORT` is applied by adding `reuse=1` to Hypnotoad listen URLs only
when the OS profile reports support and the feature is enabled.

Examples:

```text
http://*:8080        -> http://*:8080?reuse=1
http://*:8080?fd=3   -> unchanged
http+unix://...      -> unchanged
```

HTTP keep-alive is enforced through Hypnotoad `keep_alive_timeout`. Low-level
`SO_KEEPALIVE` and `TCP_NODELAY` remain Mojolicious/runtime socket concerns and
are reported in OS posture rather than patched manually in application code.

## Static Transfer

Static files and attachments are still safest behind a reverse proxy. GPForum
reports whether sendfile/X-Sendfile style delegation is available, but it does
not make Perl controllers responsible for ordinary large-file transfer.

Current modes:

- `delegated`: OS profile supports sendfile and deployment should use a reverse
  proxy or web server for large static/attachment transfer.
- `perl-fallback`: sendfile is unavailable or disabled; controllers must keep
  file responses bounded and exceptional.

## Degraded Modes

Runtime enforcement reports `degraded` when:

- configured web processes are capped by CPU policy;
- listen backlog is below the conservative floor;
- requested socket features are unsupported;
- no listen locations are configured.

Readiness includes runtime enforcement when the application provides a runtime
policy. Metrics expose the full report under `runtime_enforcement`.

## Backlog Saturation

Portable backlog saturation is not exposed consistently across macOS, FreeBSD,
and Linux. GPForum therefore reports the configured backlog and explicitly marks
runtime saturation as unavailable instead of inventing a false metric.

Linux operators can inspect kernel counters separately with tools such as
`ss`, `netstat`, `sar`, or eBPF/perf tooling. FreeBSD operators can use
`netstat`, `systat`, and `sockstat`.

## Before / After

| area | before | after |
| --- | --- | --- |
| Hypnotoad workers | described in runtime profile | configured from OS-aware runtime policy |
| Reuseport | reported in socket snapshot | applied to supported listen URLs |
| Backlog | not applied by app config | configured in Hypnotoad |
| Keep-alive | platform expectation | configured through Hypnotoad timeout |
| Graceful shutdown | supervisor concept | Hypnotoad graceful/upgrade timeout configured |
| Readiness | OS preflight only | optional runtime enforcement warning |
| Metrics | OS posture | OS posture plus runtime enforcement |

## Configuration

Environment variables:

```text
GPFORUM_RUNTIME_LISTEN=http://*:8080
GPFORUM_RUNTIME_WORKER_POLICY=cap-to-cpu
GPFORUM_RUNTIME_MAX_WEB_PER_CPU=2
GPFORUM_RUNTIME_BACKLOG=256
GPFORUM_RUNTIME_CLIENTS=250
GPFORUM_RUNTIME_REQUESTS=1000
GPFORUM_RUNTIME_KEEP_ALIVE_TIMEOUT=5
GPFORUM_RUNTIME_INACTIVITY_TIMEOUT=30
GPFORUM_RUNTIME_GRACEFUL_TIMEOUT=15
GPFORUM_RUNTIME_HEARTBEAT_INTERVAL=3
GPFORUM_RUNTIME_HEARTBEAT_TIMEOUT=2
GPFORUM_RUNTIME_UPGRADE_TIMEOUT=45
GPFORUM_RUNTIME_SPARE_PROCESSES=1
GPFORUM_RUNTIME_PROXY=1
GPFORUM_RUNTIME_PID_FILE=hypnotoad.pid
```

Feature variables:

```text
GPFORUM_OS_REUSEPORT=auto
GPFORUM_OS_SENDFILE=auto
GPFORUM_OS_STATIC_XSENDFILE=auto
GPFORUM_OS_WORKER_PRIORITY=auto
GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS=65536
```

These defaults are the small-production baseline for a real forum, not a
benchmark claim. They assume a reverse proxy, bounded PostgreSQL connections,
and `LimitNOFILE=65536` or an equivalent OS limit.

## Production Profiles

Small production, for 2-4 vCPU and 4-8 GB RAM with PostgreSQL on the same host:

```text
GPFORUM_ENV=production
GPFORUM_LOG_LEVEL=info
GPFORUM_PUBLIC_BASE_URL=https://forum.example.com
GPFORUM_WEB_PROCESSES=4
GPFORUM_WORKER_PROCESSES=2
GPFORUM_REALTIME_PROCESSES=1
GPFORUM_RUNTIME_LISTEN=http://127.0.0.1:8080
GPFORUM_RUNTIME_WORKER_POLICY=cap-to-cpu
GPFORUM_RUNTIME_MAX_WEB_PER_CPU=2
GPFORUM_RUNTIME_BACKLOG=256
GPFORUM_RUNTIME_CLIENTS=250
GPFORUM_RUNTIME_REQUESTS=1000
GPFORUM_RUNTIME_KEEP_ALIVE_TIMEOUT=5
GPFORUM_RUNTIME_INACTIVITY_TIMEOUT=30
GPFORUM_RUNTIME_GRACEFUL_TIMEOUT=20
GPFORUM_RUNTIME_HEARTBEAT_INTERVAL=5
GPFORUM_RUNTIME_HEARTBEAT_TIMEOUT=5
GPFORUM_RUNTIME_UPGRADE_TIMEOUT=60
GPFORUM_RUNTIME_SPARE_PROCESSES=1
GPFORUM_RUNTIME_PROXY=1
GPFORUM_OS_REUSEPORT=auto
GPFORUM_OS_SENDFILE=auto
GPFORUM_OS_STATIC_XSENDFILE=auto
GPFORUM_OS_WORKER_PRIORITY=auto
GPFORUM_OS_AFFINITY=off
GPFORUM_OS_MIN_RECOMMENDED_WORKERS=2
GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS=65536
GPFORUM_LOCAL_CACHE_MAX_ENTRIES=2048
GPFORUM_CATEGORY_CACHE_TTL_SECONDS=60
GPFORUM_REALTIME_LISTENER_ENABLED=1
GPFORUM_REALTIME_LISTENER_POLL_INTERVAL_SECONDS=1
GPFORUM_REALTIME_LISTENER_RECONNECT_BACKOFF_SECONDS=5
GPFORUM_REALTIME_LISTENER_HEARTBEAT_INTERVAL_SECONDS=30
GPFORUM_MINION_ENABLED=0
```

Medium production, for 4-8 vCPU and 8-16 GB RAM with PostgreSQL separated or
explicitly tuned:

```text
GPFORUM_WEB_PROCESSES=8
GPFORUM_WORKER_PROCESSES=4
GPFORUM_REALTIME_PROCESSES=2
GPFORUM_RUNTIME_BACKLOG=512
GPFORUM_RUNTIME_CLIENTS=500
GPFORUM_RUNTIME_REQUESTS=2000
GPFORUM_RUNTIME_KEEP_ALIVE_TIMEOUT=5
GPFORUM_RUNTIME_INACTIVITY_TIMEOUT=30
GPFORUM_RUNTIME_GRACEFUL_TIMEOUT=30
GPFORUM_RUNTIME_UPGRADE_TIMEOUT=60
GPFORUM_LOCAL_CACHE_MAX_ENTRIES=8192
GPFORUM_CATEGORY_CACHE_TTL_SECONDS=120
GPFORUM_MINION_ENABLED=1
GPFORUM_MINION_PG_URL=postgresql://gpforum_worker:password@127.0.0.1/gpforum
```

## Acceptance Commands

```sh
script/gpforum-os-preflight --json
carton exec prove -lr t/52-os-preflight.t t/53-os-runtime-policy.t
script/perlcritic --severity 5
```
