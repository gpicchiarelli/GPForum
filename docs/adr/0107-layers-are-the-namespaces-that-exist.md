# ADR 0107: The Layers Are the Namespaces That Exist

## Status

Accepted. Amends ADR 0052 (its recommended module structure) and ADR 0064
(its recommended namespaces and layering).

## Context

ADR 0064 makes two things binding: the platform MUST maintain explicit
architectural layers, and dependencies MUST flow inward. It recommends the
layers Domain, Application, Infrastructure, Transport/Delivery and Rendering,
and ADR 0052 recommends matching namespaces — `GPForum::Domain`,
`GPForum::Application` and so on.

The code grew in other namespaces. When this was measured, `lib/` held 402
modules: 160 in `GPForum::Service`, 61 in `GPForum::Schema`, 39 in
`GPForum::Controller`, and so on down — and one module each in `Domain`,
`Application` and `Query`. `ARCHITECTURE.md`'s layer map listed the
recommended namespaces as "future" boundaries, so the declared layering
described two modules. `GPForum::Query::ReadModel` was loaded by nothing but
the test that loads every module. Neither MUST was checked by anything.

Measured, the real dependency graph was already close to layered. Controllers
reach services only through helpers; `Bootstrap` is the composition root;
nearly every edge points downward. Seven did not:

- `Service::Operations::StagingDrill` ran two CLI commands, `Command::Migrate`
  and `Command::PerformanceSeed`;
- `Service::Outbox::DomainEventTransport` used a worker's module,
  `Worker::HandlerIdempotency`;
- `Infrastructure::EventRecorder` used two services, `Service::Id` and
  `Service::Outbox::MessageBuilder`;
- `Command::OutboxDispatch` and `Command::ScheduledJobs` built the application
  class themselves when not given one.

## Decision

The layers are the namespaces that hold the code. Lowest first:

| Layer | Namespaces | Holds |
| --- | --- | --- |
| foundation | `Config`, `Log`, `Runtime`, `OS`, `Domain`, `Jobs`, `Schema`, `Migration`, `Infrastructure` | configuration, persistence, cross-cutting contracts |
| service | `Service` | the application: rules, workflows, readers, stores |
| presentation | `Web`, `ViewModel`, `View`, `Theme`, `Security`, `I18N` | turning service results into pages and headers |
| adapter | `Controller`, `Command`, `Worker`, `Benchmark` | the ways in: HTTP, the command line, jobs |
| composition | the `GPForum` class, `Bootstrap`, `CLI`, `Application` | wiring the others together |

A module MAY depend on its own layer and on any layer below it, and MUST NOT
depend on a layer above. This is ADR 0064's "dependencies MUST flow inward",
made checkable. `GPForum::Application::LayerMap` declares the layers;
`t/192-layering.t` checks every module in `lib/` against it — `use`,
`require`, a `Mojo::Base`/`parent`/`base` superclass, and a `Class->method`
call — and fails on a module whose namespace belongs to no layer, so a new
namespace is placed before it lands. `script/architecture-check` runs the same
test.

The seven upward edges are removed:

- `Service::Id` becomes `Infrastructure::Id` and `Service::Outbox::MessageBuilder`
  becomes `Infrastructure::OutboxMessageBuilder`: an id generator and the
  outbox row builder are infrastructure the event recorder composes.
- `Worker::HandlerIdempotency` becomes `Service::Outbox::HandlerIdempotency`,
  below both the transport and the workers that use it.
- `StagingDrill` applies migrations through `Migration::Runner`, as
  `migrate --apply` does, and receives its seed step from `Command::StagingDrill`.
- The two commands receive the application, or a builder for it, from their
  entry points, which are composition: `bin/` scripts and `GPForum::CLI::*`.

`GPForum::Query::ReadModel` is removed. The mapping to ADR 0064's names is:
Domain and Infrastructure are foundation, Application is service, Rendering is
presentation, Transport/Delivery is adapter.

## Consequences

- The declared layering and the code are the same thing, and a change that
  breaks it fails the suite.
- This is a layered architecture, not a hexagonal one. Services read and
  write through DBIx::Class directly, so business logic is not
  infrastructure-independent in the strict sense ADR 0064 recommends. That
  recommendation is not met and this ADR does not pretend otherwise; the
  binding rule — explicit layers, dependencies pointing inward — is.
- Placement is by top-level namespace. A module that belongs to another layer
  moves to that layer's namespace; there is no exception list to grow.
- `Command::PerformanceSeed` holds its logic in the adapter layer, which is
  why `StagingDrill` has to be handed the seed step rather than calling a
  service. Moving that logic into `Service` would let the drill call it
  directly.

## Alignment

- ADR 0052, ADR 0064 — the recommendations this amends.
- `lib/GPForum/Application/LayerMap.pm` — the declaration.
- `t/192-layering.t`, `script/architecture-check` (`check_layering`) — the
  guard, confirmed to fail on the tree before this change.
- `ARCHITECTURE.md` — the layer map.
