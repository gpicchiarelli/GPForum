# Query Budget Policy

GPForum keeps hot SSR routes bounded and observable through
`GPForum::Service::Operations::QueryBudget`.

## Covered Endpoints

The catalog includes budgets for:

- `thread_view`
- `category_threads`
- `moderation_reports`
- `search`
- `notifications`

Additional admin, moderation, posting, reporting and autocomplete endpoints are
also cataloged so benchmark evidence can compare route behavior consistently.

`script/query-budget --sync` writes a catalog row only when max queries,
transactions, or notes differ from the stored budget. An already-aligned
catalog is a no-op. A unique race on `endpoint_name` reuses the existing
row and does not rewrite the catalog when those values match.

## Observations

The DBIx::Class statistics observer records per request:

- SQL query count;
- transaction count;
- duplicate normalized SQL fingerprints;
- route name;
- endpoint budget status.

Duplicate queries are treated as N+1 warning evidence. Budgets currently allow
zero duplicate SQL fingerprints by default for cataloged endpoints.

## Enforcement

Observation is always active when the schema observer is attached. Hard-fail
mode is opt-in for non-production:

```sh
GPFORUM_QUERY_BUDGET_ENFORCE=1 carton exec prove -lr t
```

In hard-fail mode, a budget violation throws after dispatch. Production remains
observational so user traffic degrades through metrics and release gates rather
than crashing a response path.

## Benchmark Headers

When `GPFORUM_BENCHMARK_QUERY_HEADERS=1`, responses include:

- `X-GPForum-DB-Queries`
- `X-GPForum-DB-Transactions`
- `X-GPForum-DB-Duplicate-Queries`
- `X-GPForum-DB-Budget`
- `X-GPForum-DB-Budget-Endpoint`
- `X-GPForum-DB-Budget-Max-Queries`

