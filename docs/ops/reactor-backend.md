# Reactor backend

Date: 2026-06-02.

This document explains the following observed anomaly:

```text
declared_event_backend=epoll
actual_reactor=Mojo::Reactor::Poll
```

## Diagnosis

`declared_event_backend` describes the OS posture the runtime profile wants or
declares. `actual_reactor` is the class Mojolicious actually uses in that Perl
process.

On macOS, `Mojo::Reactor::Poll` is expected: `epoll` is Linux-specific and
cannot be the real backend. On Linux, `epoll` does not appear as a native
Mojolicious reactor unless the environment provides compatible dependencies and
event loop, and Mojolicious selects a reactor other than Poll. The mismatch must
therefore be treated as a diagnostic signal, not as a universal error.

## Repository state

The repository already carries runtime evidence:

- `lib/GPForum/OS/RuntimeEvidence.pm` records the declared reactor, the expected
  reactor, the actual reactor, and a recommendation;
- `docs/OS_RUNTIME_EVIDENCE.md` documents the local mismatch;
- `t/58-os-runtime-evidence.t` covers OS profiles and fallbacks;
- `t/57-hypnotoad-benchmark.t` verifies that the benchmark report includes
  `actual_reactor`.

## Operational rule

| Environment | Expected behavior | Gate |
| --- | --- | --- |
| macOS dev | `Mojo::Reactor::Poll` is acceptable | diagnostic warning |
| FreeBSD dev/staging | fallback acceptable when documented | diagnostic warning |
| Linux production | mismatch must be investigated | fail only in strict preflight |
| Generic CI | do not assume epoll | portable test, no false failure |

## Proposed patch

Do not force a new reactor as a mandatory dependency. Make the message clearer
first:

- distinguish `declared_event_backend` from `actual_reactor`;
- report the detected OS;
- state whether the mismatch is expected on a non-Linux OS;
- under `--strict`, fail only when the profile declares Linux/epoll and the
  production target explicitly requires a native reactor.

## Required tests

1. macOS/fallback: an epoll/Poll mismatch produces a warning, not a failure.
2. Linux strict: a production profile that requires a native backend, with Poll
   as the actual reactor, produces a diagnostic failure.
3. CI portability: the test does not assume epoll when `uname` is not Linux.
4. Benchmark report: `actual_reactor` and the recommendation stay visible in
   both text and JSON output.

## Deploy

In production, do not use the reactor as the only readiness proof. Check it
together with:

- `/health/ready`;
- query plan evidence;
- Hypnotoad benchmarks with real workers;
- file descriptors and backlog;
- p95/p99 request latency;
- outbox pending/failed/dead-letter counts.
