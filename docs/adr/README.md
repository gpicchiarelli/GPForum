# Architecture Decision Records

ADRs record durable decisions and deviations from the architectural prompts.

Create a new ADR when a change alters:

- Perl-first runtime assumptions;
- PostgreSQL-authoritative storage;
- Redis/KeyDB optionality;
- SSR-first rendering;
- bounded context ownership;
- permission, privacy, audit, migration, or failure models.

Use [0000-template.md](0000-template.md).


## Index

<!-- adr-index:start -->
| ADR | Decision | Status |
| --- | --- | --- |
| [0001](0001-ssr-ui-system.md) | SSR UI System Foundation | Accepted |
| [0002](0002-bootstrap-boundaries.md) | Bootstrap Boundaries | Accepted |
| [0003](0003-ssr-view-models.md) | SSR View Models | Accepted |
| [0004](0004-semantic-template-architecture.md) | Semantic SSR Template Architecture | Accepted |
| [0005](0005-posting-workflow-boundary.md) | Posting Workflow Boundary | Accepted |
| [0006](0006-listen-notify-realtime-transport.md) | PostgreSQL LISTEN/NOTIFY Realtime Transport | Accepted |
| [0007](0007-websocket-authorization-policy.md) | Strict Websocket Subscription Authorization | Accepted |
| [0008](0008-realtime-event-contracts.md) | Versioned Realtime Event Contracts | Accepted |
| [0009](0009-outbox-retry-semantics.md) | Outbox Retry And Dead-Letter Semantics | Accepted |
| [0010](0010-moderation-workflow-boundary.md) | Moderation Workflow Boundary | Accepted |
| [0011](0011-admin-workflow-boundary.md) | Admin Workflow Boundary | Accepted |
| [0012](0012-operational-profiles.md) | Operational Profiles and Partition Lifecycle | Accepted |
| [0013](0013-privacy-workflow-boundary.md) | Privacy Workflow Boundary | Accepted |
| [0014](0014-identity-workflow-boundary.md) | Identity Workflow Boundary | Accepted |
| [0015](0015-attachment-notification-workflow-boundary.md) | Attachment and Notification Workflow Boundaries | Accepted |
| [0016](0016-shared-http-access.md) | Shared HTTP Access Decisions | Accepted |
| [0017](0017-realtime-handshake-access.md) | Realtime Handshake Access Decisions | Accepted |
| [0018](0018-cookie-session-ownership.md) | Cookie Session Field Ownership | Accepted |
| [0019](0019-public-cache-access.md) | Public HTTP Cache Access Decisions | Accepted |
| [0020](0020-audit-record-hashing.md) | Audit Record Hashing Boundary | Accepted |
| [0021](0021-i18n-boundaries.md) | I18N Catalog, Locale, and Formatter Boundaries | Accepted |
| [0022](0022-attachment-download-access.md) | Attachment Download Access Boundary | Accepted |
| [0023](0023-privacy-erasure-record.md) | Privacy Erasure and Record Boundaries | Accepted |
| [0024](0024-forum-view-model-boundaries.md) | Forum View-Model Form, Page, and Row Boundaries | Accepted |
| [0025](0025-outbox-failure-retry-claim.md) | Outbox Failure, Retry, and Claim Query Boundaries | Accepted |
| [0026](0026-home-page-access.md) | Home Page Access Contract | Accepted |
| [0027](0027-attachment-lifecycle.md) | Attachment Upload, Scan, and Delete Lifecycle | Accepted |
| [0028](0028-identity-text-error-access.md) | Identity Text Error Access | Accepted |
| [0029](0029-privacy-completion-replay.md) | Privacy Approval and Completion Replay | Accepted |
| [0030](0030-discovery-access.md) | Discovery Reader Limits And Document Rendering | Accepted |
| [0031](0031-attachment-event.md) | Attachment Event And Audit Hashes | Accepted |
| [0032](0032-privacy-event.md) | Privacy Event And Audit Hashes | Accepted |
| [0033](0033-retention-hold-event.md) | Retention Hold Event And Audit Hashes | Accepted |
| [0034](0034-identity-event.md) | Identity Event And Audit Hashes | Accepted |
| [0035](0035-moderation-action-event.md) | Moderation Action Event And Audit Hashes | Accepted |
| [0036](0036-moderation-report-event.md) | Moderation Report Event And Audit Hashes | Accepted |
| [0037](0037-moderation-suspension-event.md) | Moderation Suspension Event And Audit Hashes | Accepted |
| [0038](0038-admin-event.md) | Admin Catalog And Binding Audit Hashes | Accepted |
| [0039](0039-identity-login-logout-event.md) | Identity Login And Logout Audit Hashes | Accepted |
| [0040](0040-attachment-orphan-cleanup.md) | Attachment Orphan Cleanup Policy | Accepted |
| [0041](0041-forum-access.md) | Forum Rate Limits And Input Policy | Accepted |
| [0042](0042-attachment-access.md) | Attachment Upload Limits And HTTP Policy | Accepted |
| [0043](0043-notification-access.md) | Notification Page Limits And HTTP Policy | Accepted |
| [0044](0044-moderation-access.md) | Moderation Queue Limits And HTTP Policy | Accepted |
| [0045](0045-privacy-access.md) | Privacy Page Limits And HTTP Policy | Accepted |
| [0046](0046-admin-access.md) | Admin Page Limits And HTTP Policy | Accepted |
| [0047](0047-metrics-token-access.md) | Metrics Token Access Decisions | Accepted |
| [0048](0048-mandatory-glifistore-l2.md) | Mandatory GlifiStore L2 Cache | Accepted |
| [0049](0049-foundational-architecture.md) | Foundational Architecture Constitution | Accepted |
| [0050](0050-infrastructure-distributed-systems.md) | Infrastructure and Distributed Systems Constitution | Accepted |
| [0051](0051-database-architecture.md) | Database Architecture Constitution | Accepted |
| [0052](0052-perl-engineering-discipline.md) | Perl Engineering and Coding Discipline Constitution | Accepted |
| [0053](0053-security-architecture.md) | Security Architecture Constitution | Accepted |
| [0054](0054-frontend-rendering-theme-system.md) | Frontend, Rendering and Theme System | Accepted |
| [0055](0055-event-driven-realtime-synchronization.md) | Event-Driven, Realtime and Distributed Synchronization | Accepted |
| [0056](0056-worker-queue-asynchronous-processing.md) | Worker, Queue and Asynchronous Processing | Accepted |
| [0057](0057-authorization-moderation-governance.md) | Authorization, Moderation and Governance | Accepted |
| [0058](0058-observability-logging-operational-intelligence.md) | Observability, Logging and Operational Intelligence | Accepted |
| [0059](0059-cicd-quality-release-engineering.md) | CI/CD, Quality Assurance and Release Engineering | Accepted |
| [0060](0060-api-integration-external-interfaces.md) | API, Integration and External Interfaces | Accepted |
| [0061](0061-domain-model-core-entities.md) | Domain Model, Core Entities and Business Architecture | Accepted |
| [0062](0062-search-indexing-information-retrieval.md) | Search, Indexing and Information Retrieval | Accepted |
| [0063](0063-performance-scalability-capacity.md) | Performance, Scalability and Capacity Engineering | Accepted |
| [0064](0064-software-engineering-governance.md) | Software Engineering And Architecture Governance | Accepted |
| [0065](0065-community-operations-product-behavior.md) | Community Operations, Forum Structure And Product Behavior | Accepted |
| [0066](0066-redis-free-architecture-memo.md) | Redis-Free Architecture Exploration | Accepted |
| [0067](0067-cache-coordination-redis-decision.md) | Cache, Coordination And Redis Decision | Accepted |
| [0068](0068-mvp-roadmap-sequencing.md) | MVP Roadmap And Implementation Sequencing | Accepted |
| [0069](0069-initial-database-schema-blueprint.md) | Initial Database Schema And Persistence Blueprint | Accepted |
| [0070](0070-permission-matrix-authorization-rules.md) | Permission Matrix And Authorization Rules | Accepted |
| [0071](0071-event-catalog-workflow-contracts.md) | Event Catalog And Workflow Contracts | Accepted |
| [0072](0072-http-routes-controllers-workflow.md) | HTTP Routes, Controllers and Application Workflow | Accepted |
| [0073](0073-ux-information-architecture.md) | UX, Information Architecture and Interface Behavior | Accepted |
| [0074](0074-privacy-data-protection-legal-operations.md) | Privacy, Data Protection and Legal Operations | Accepted |
| [0075](0075-operational-runbooks.md) | Operational Runbooks and Production Procedures | Accepted |
| [0076](0076-bootstrap-implementation.md) | Bootstrap Implementation | Accepted |
| [0077](0077-configuration-environments-feature-flags.md) | Configuration, Environments and Feature Flags | Accepted |
| [0078](0078-email-notification-delivery.md) | Email, Notification Delivery and Communication | Accepted |
| [0079](0079-admin-console-staff-operations.md) | Admin Console and Staff Operations | Accepted |
| [0080](0080-content-policy-enforcement.md) | Content Policy, Community Guidelines and Enforcement | Accepted |
| [0081](0081-import-export-legacy-migration.md) | Import, Export and Legacy Migration | Accepted |
| [0082](0082-seo-public-discovery-syndication.md) | SEO, Public Discovery and Syndication | Accepted |
| [0083](0083-plugin-extension-hook-system.md) | Plugin, Extension and Hook System | Accepted |
| [0084](0084-test-strategy-quality-verification.md) | Test Strategy and Quality Verification | Accepted |
| [0085](0085-api-contracts-openapi-websocket-schema.md) | API Contracts, OpenAPI and Websocket Schema | Accepted |
| [0086](0086-packaging-deployment-runtime-processes.md) | Packaging, Deployment and Runtime Processes | Accepted |
| [0087](0087-adr-governance-architecture-evolution.md) | ADR Governance and Architecture Evolution | Accepted |
| [0088](0088-perl-multi-process-runtime-scalability.md) | Perl Multi-Process, Threading and Dynamic Runtime Scalability | Accepted |
| [0089](0089-profiling-coverage-perl-automation.md) | Profiling, Coverage and Perl Automation | Accepted |
| [0090](0090-postgresql-native-search.md) | PostgreSQL-Native Search and Perl Retrieval | Accepted |
| [0091](0091-executable-architecture-contract.md) | Executable Architecture Contract | Accepted |
| [0092](0092-github-project-success-contract.md) | GitHub Project Success Contract | Accepted |
| [0093](0093-verifiable-engineering-invariants.md) | Verifiable Engineering Invariants Constitution | Accepted |
| [0094](0094-accessibility-engineering.md) | Accessibility Engineering Constitution | Accepted |
| [0095](0095-human-centered-community-lifecycle.md) | Human-Centered Community Lifecycle Constitution | Accepted |
| [0096](0096-core-boundary-architectural-discipline.md) | Core Boundary And Architectural Discipline Constitution | Accepted |
| [0097](0097-os-level-performance.md) | OS-Level Performance Constitution | Accepted |
| [0098](0098-execution-constitution-operational-integrity.md) | Execution Constitution For Operational Integrity | Accepted |
| [0099](0099-operational-scalability-projection-stability.md) | Operational Scalability And Projection Stability Execution Constitution | Accepted |
| [0100](0100-domain-integrity-authorization-moderation.md) | Domain Integrity, Authorization And Moderation Execution Constitution | Accepted |
| [0101](0101-search-feed-syndication-retrieval.md) | Search, Feed, Syndication And Retrieval Execution Constitution | Accepted |
| [0102](0102-effective-visibility.md) | Effective Visibility | Accepted |
| [0105](0105-json-column-serialization.md) | JSON Column Serialization | Accepted |
| [0106](0106-authorization-methods-are-named-permits.md) | Authorization Methods Are Named `permits`, Not `can` | Accepted |
| [0107](0107-layers-are-the-namespaces-that-exist.md) | The Layers Are the Namespaces That Exist | Accepted |
| [0108](0108-uploads-scanned-by-the-system-antivirus.md) | Uploads Are Scanned by the Operating System's Free Antivirus | Accepted |
| [0109](0109-gpforum-is-an-application.md) | GPForum Is an Application, Not a CPAN Distribution | Accepted |
| [0110](0110-adr-0091-interfaces-are-the-modules-that-exist.md) | ADR 0091's Mandatory Interfaces Are the Modules That Exist | Accepted |
| [0111](0111-production-scaling-directives-verified.md) | Production Scaling Directives, Verified Against the Code | Accepted |

Generated by `script/adr-index` from the files in this directory; `script/adr-index --check` fails when it is stale.
Numbers 0103, 0104 were never assigned. They are left unused rather than
renumbered, because other documents cite ADRs by number.

<!-- adr-index:end -->
