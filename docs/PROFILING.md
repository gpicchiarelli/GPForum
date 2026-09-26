# GPForum Profiling

Date: 2026-05-28.

Profiling is mandatory for performance changes. Keep the workflow local,
repeatable, and compatible with a single VPS deployment.

## HTTP / Perl CPU

Profile one route with NYTProf:

```sh
script/profile-nytprof --route /t/thread-1 --fixture --iterations 3 --warmup 1
```

Profile an arbitrary Perl command:

```sh
script/profile -- script/bench-outbox-dispatcher --messages 10000 --workers 4
```

Expected artifacts:

* `nytprof.out`
* rendered NYTProf HTML when generated locally
* benchmark JSON under `artifacts/`

## Query Plans

Static gate:

```sh
script/query-plan-check
```

DB-backed gate when PostgreSQL is configured:

```sh
script/query-plan-evidence --check --analyze --profile medium
```

Use `--endpoint outbox_claim`, `--endpoint thread_view`, or another endpoint to
isolate a plan. Prohibited regressions: unauthorized `Seq Scan`, hot-path
`OFFSET`, large sort, explosive nested loop.

## Outbox

Fixture benchmark:

```sh
script/bench-outbox-dispatcher \
  --messages 1000,10000,100000 \
  --workers 1,2,4,8 \
  --batch-size 100 \
  --json \
  --artifact artifacts/outbox-dispatcher.json
```

Required checks:

* `status=ok`
* `lost=0`
* `duplicates=0`
* expected ack batch count equals message count divided by batch size
* p95 claim latency is recorded

## HTTP Benchmarks

Fixture smoke:

```sh
script/benchmark-http --fixture --check --iterations 2 --warmup 1
```

Configured PostgreSQL run:

```sh
script/seed-benchmark --profile medium
script/benchmark-http --configured --check --iterations 20 --warmup 3
```

Hypnotoad prefork run:

```sh
script/bench-hypnotoad --check --profile medium --workers 2,4 \
  --iterations 10 --warmup 2 --route / --route /t/thread-1
```

## Memory

Benchmark reports include RSS where the harness supports it. For soak work,
record RSS before, during, and after:

```sh
ps -o pid,rss,command -p <pid>
```

Watch for monotonic RSS growth under:

* public thread rendering loops
* websocket fanout
* outbox dispatch loops
* upload/media processing

## Regression Rule

A performance patch is incomplete unless it states:

* command used;
* dataset/profile;
* before/after or current baseline;
* p50/p95/p99 where relevant;
* query-plan status;
* duplicate/lost counts for outbox or realtime delivery paths.
