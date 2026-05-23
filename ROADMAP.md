# Roadmap

The roadmap follows [prompt/20.txt](prompt/20.txt) and must remain consistent
with [prompt/43.txt](prompt/43.txt).

## Active Direction

- Complete identity/session hardening.
- Expand forum write and read workflows.
- Connect outbox events to worker handlers.
- Build PostgreSQL-native search indexing.
- Add notification delivery channels.
- Add moderation and audit review interfaces.

## Release Readiness

A public release requires:

- stable migrations and rollback discipline;
- CI green on every pull request;
- coverage and profiling artifacts for hot paths;
- security policy and private reporting path;
- documented support boundaries;
- ADR coverage for major deviations.

