# GPForum documentation

Start with the [project README](../README.md) for the overview. The documents
below go deeper, grouped by what you are trying to do.

## Understand the system

| Document | What it covers |
| --- | --- |
| [ARCHITECTURE.md](../ARCHITECTURE.md) | The SSR-first modular monolith and its boundaries |
| [architecture/](architecture) | Bootstrap, presentation, web access, per-area workflow boundaries, operational profiles, partition lifecycle, and the longevity review |
| [EVENTS.md](../EVENTS.md) | Event envelope and delivery contracts |
| [OUTBOX_LIFECYCLE.md](OUTBOX_LIFECYCLE.md) | Transactional outbox, retries, and dead letters |
| [realtime.md](realtime.md) | Realtime as an enhancement boundary |
| [VIEW_MODELS.md](VIEW_MODELS.md) | SSR view models between controllers and templates |
| [i18n.md](i18n.md) | Locale negotiation and translation boundaries |
| [adr/](adr) | Architecture decision records |

## Use the product

| Document | What it covers |
| --- | --- |
| [MVP.md](MVP.md) | Every route that is traversable today |
| [PRODUCT_FLOWS.md](PRODUCT_FLOWS.md) | Product workflows present in the repository |
| [API.md](../API.md) | API posture: JSON responses today, versioning rules for later |

## Deploy and operate

| Document | What it covers |
| --- | --- |
| [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) | The release contract: environment, gates, backup, deploy |
| [DEPLOYMENT.md](DEPLOYMENT.md) · [DEPLOYMENT_EVIDENCE.md](DEPLOYMENT_EVIDENCE.md) | Running GPForum behind a reverse proxy, and the evidence gate |
| [OPERATIONAL_BASELINE.md](OPERATIONAL_BASELINE.md) · [BASELINE.md](BASELINE.md) | Current operational baseline |
| [OBSERVABILITY.md](OBSERVABILITY.md) | Health, logs, and metrics |
| [ops/reactor-backend.md](ops/reactor-backend.md) | Declared versus actual event-loop reactor |
| [ops/scheduled-jobs.md](ops/scheduled-jobs.md) | Hourly retention/orphan cleanup command |
| [ops/dead-letters.md](ops/dead-letters.md) | Inspect, keep, or purge exhausted outbox messages |
| [ops/mail-check.md](ops/mail-check.md) | Identity mail transport dry-run / SMTP probe |
| [ops/staging-drills.md](ops/staging-drills.md) | Throwaway migrate / dump / attachments / deploy checklist |
| [ops/staging-host.md](ops/staging-host.md) | Live staging Hypnotoad+TLS bring-up and verify |
| [ops/stress-load.md](ops/stress-load.md) | Concurrent HTTP stress profiles against a base URL |
| [ops/private-beta-checklist.md](ops/private-beta-checklist.md) | Operator private-beta go/no-go aggregate (print-only) |
| [ops/evidence/](ops/evidence) | Archived operator evidence blobs (laptop vs staging; never a beta claim) |
| [ops/evidence-validate.md](ops/evidence-validate.md) | Validate operator-captured evidence JSON before archiving it |
| [release/readiness-review.md](release/readiness-review.md) | Latest go / no-go review |

## Performance

| Document | What it covers |
| --- | --- |
| [PERFORMANCE.md](PERFORMANCE.md) | Performance readiness |
| [PERFORMANCE_BASELINE.md](PERFORMANCE_BASELINE.md) · [PERFORMANCE_EVIDENCE.md](PERFORMANCE_EVIDENCE.md) · [PERFORMANCE_AUDIT.md](PERFORMANCE_AUDIT.md) | Baseline numbers, evidence gate, and audit |
| [DB_PERFORMANCE.md](DB_PERFORMANCE.md) · [QUERY_BUDGET_POLICY.md](QUERY_BUDGET_POLICY.md) | Query shape, indexes, and per-route query budgets |
| [PROFILING.md](PROFILING.md) | Devel::NYTProf workflow |
| [OS_OPTIMIZATION.md](OS_OPTIMIZATION.md) · [OS_RUNTIME_ENFORCEMENT.md](OS_RUNTIME_ENFORCEMENT.md) · [OS_RUNTIME_EVIDENCE.md](OS_RUNTIME_EVIDENCE.md) | OS-level performance contract and evidence |

## Security and correctness

| Document | What it covers |
| --- | --- |
| [SECURITY_BASELINE.md](SECURITY_BASELINE.md) · [SECURITY_HARDENING.md](SECURITY_HARDENING.md) | Security baseline and abuse hardening |
| [ENGINEERING_CORRECTNESS.md](ENGINEERING_CORRECTNESS.md) | Engineering correctness freeze |
| [audit/](audit) | Audits of transactional correctness, failure modes, and the email lifecycle |
| [CPAN_LICENSE_REVIEW.md](CPAN_LICENSE_REVIEW.md) | Dependency license gate |

## Interface

| Document | What it covers |
| --- | --- |
| [UI_SYSTEM.md](UI_SYSTEM.md) · [ui/design-system.md](ui/design-system.md) | SSR design system built from Mojolicious partials |
| [UI_ACCESSIBILITY.md](UI_ACCESSIBILITY.md) · [ui/accessibility.md](ui/accessibility.md) | WCAG 2.2 AA guidelines |
| [THEMING.md](../THEMING.md) | Themes and design tokens |
