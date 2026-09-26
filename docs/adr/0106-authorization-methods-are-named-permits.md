# ADR 0106: Authorization Methods Are Named `permits`, Not `can`

## Status

Accepted. Amends ADR 0091.

## Context

ADR 0091 lists `PermissionEngine` among its Mandatory Interfaces with the
method `can($actor, $action, $resource, $context)`, and says implementations
MUST NOT remove a contract method without an ADR. This is that ADR.

Every Perl object already has a method called `can`: `UNIVERSAL::can`, which
answers whether an object implements a named method. Defining `sub can` in a
class replaces it for every caller. `Search::PermissionEngine` and
`Realtime::SubscriptionPolicy` both did, so `$engine->can('some_method')`
stopped reporting whether a method exists and started asking an authorization
question with the method name as the actor.

This was not theoretical. When `search_condition` was added to
`Search::PermissionEngine`, the capability probe `$engine->can(...)` called the
authorization method instead, and had to be rewritten to `UNIVERSAL::can` with
a comment explaining why. Once subroutine signatures landed the failure became
loud rather than silent — `can` with two arguments died on arity — but a loud
failure in a probe is still a failure in a probe.

## Decision

The authorization method on a permission engine or policy is `permits`, with
the same arguments ADR 0091 gives `can`:

    permits($actor, $action, $resource, $context)

No class in `lib/` or `t/` may define `sub can`. `script/architecture-check`
enforces this and was confirmed to fail when one is added.

Everything else in ADR 0091's `PermissionEngine` entry stands, including the
methods that do not exist yet.

## Consequences

- `UNIVERSAL::can` answers the question it is for, on every object, so generic
  code can probe for capabilities without knowing which classes are
  authorization engines.
- Call sites say what they mean: `->permits(...)` reads as a permission check
  where `->can(...)` read as a capability check.
- The six call sites and both test doubles were changed together; there is no
  compatibility alias, because an alias named `can` would reintroduce the
  override this removes.
- Rollback is a rename in the other direction and would bring the hazard back;
  there is no reason to expect one.

## State of ADR 0091's Mandatory Interfaces

Recorded here because the rename touched one of them, and because ADR 0091
states that these interfaces MUST exist. Measured against `lib/` on
2026-09-24:

| Interface | Present |
| --- | --- |
| `SearchIndexer` | all five methods |
| `SessionStore` | `create_session`, `revoke_session`; not `find_active_session`, `revoke_all_for_user`, `touch_session` |
| `NotificationDispatcher` | `create_notification`, `mark_read`; not `dispatch_pending`, `suppress_for_policy` |
| `PermissionEngine` | `permits` (formerly `can`); not `explain`, `roles_for`, `policies_for` |
| `EventStore` | module absent |
| `CommandHandler` | module absent |

One of the six is complete. This ADR does not change that and does not relax
ADR 0091's requirement; it records the distance so that the contract is not
read as describing the code. Closing it is tracked in `docs/QUALITY_PROGRAM.md`.

## Alignment

- ADR 0091 — the contract this amends.
- `lib/GPForum/Service/Search/PermissionEngine.pm`,
  `lib/GPForum/Service/Realtime/SubscriptionPolicy.pm` — the implementations.
- `script/architecture-check` (`check_universal_can_override`) — the guard.
- `t/19-search.t`, `t/81-realtime-operational.t` — the renamed call sites.
