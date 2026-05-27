# Bootstrap Architecture

`lib/GPForum.pm` is the composition root. It loads configuration, builds runtime
policy, and delegates helper, hook, and route registration to focused bootstrap
modules.

Startup order matters:

1. `GPForum::Bootstrap::Core` configures secrets, mode, static assets, clock,
   ids, and realtime hub.
2. `GPForum::Bootstrap::Security` installs session and response security
   policy.
3. `GPForum::Bootstrap::I18N` builds the i18n service and registers UI helpers
   through `GPForum::Bootstrap::UI`.
4. `GPForum::Bootstrap::Operations` wires schema, runtime, cache, rate limits,
   metrics, readiness, query stats, and telemetry.
5. Product bootstraps register identity, discovery, forum, admin, moderation,
   and privacy services.
6. `GPForum::Bootstrap::Routes` registers named routes last.

Helpers are part of the public internal contract. Controller code should depend
on helper names, not on bootstrap module internals. `t/73-bootstrap-composition.t`
asserts that helpers resolve, every bootstrap helper is registered exactly once,
and controller helper calls are backed by bootstrap registrations.

Bootstrap modules should not implement business logic. They construct service
boundaries and keep DBIx::Class access inside stores/readers/services.
