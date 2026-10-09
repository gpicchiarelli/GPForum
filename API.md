# GPForum API Preparation

GPForum currently exposes SSR routes and JSON-compatible responses on selected
routes. The API posture is preparation-first: do not introduce a separate API
surface until contracts are explicit and tested.

## Versioning

Future REST routes should live under:

```text
/api/v1/...
```

Versioned APIs must preserve:

- stable JSON response envelopes;
- explicit authentication and authorization;
- CSRF-free token auth only for non-browser clients;
- browser routes continuing to use CSRF-protected sessions;
- event/audit consistency for writes.

## Internal Contracts

Until `/api/v1` exists, JSON compatibility is maintained by presenters and
controller response helpers. Existing JSON fields must not be renamed without a
compatibility test.

## Token Architecture

Future bot/mobile integrations should use a dedicated token boundary:

- token hashes stored server-side;
- scoped permissions through RBAC/ABAC;
- short-lived access tokens where possible;
- revocation audit;
- rate limits per token, actor, and IP class.

Session cookies remain the browser default.
