# ADR 0095: Human-Centered Community Lifecycle Constitution

## Status

Accepted. Converted on 2026-09-19 from `prompt/47.txt` ("GPForum -
Human-Centered Community Lifecycle Constitution"); this ADR replaces the
prompt as the binding source.

## Context

This constitution defines the mandatory community lifecycle, emotional
usability, social continuity, engagement ergonomics, contributor identity,
retention, discovery, personalization, and long-term human-centered
operation doctrine of GPForum. It is mandatory.

It moves GPForum from infrastructure-first forum architecture to durable
human-centered community platform architecture without compromising
PostgreSQL-first authoritative storage, Perl-first implementation, SSR-first
rendering, explicit governance, operational simplicity, auditability,
rebuildable projections, moderation authority, permission-safe rendering,
graceful degradation, and anti-dark-pattern philosophy.

It governs product behavior across the Forum, Identity (profiles),
Notifications, Search and discovery, Moderation, Admin, and realtime
presence surfaces.

GPForum explicitly rejects manipulative engagement systems, addictive dark
patterns, opaque behavioral ranking, hostile UX, attention-maximization
incentives, infinite-scroll addiction architecture, exploitative
gamification, and hidden ranking manipulation.

GPForum preserves explainability, operational clarity, moderation authority,
privacy boundaries, accessibility, and archival durability.

## Decision

### 1. Human-Centered Community Philosophy

- Forums are social memory systems.
- Community continuity, emotional usability, readability, contributor
  recognition, long-form discussion, healthy return behavior, and durable
  participation matter.
- Software quality includes emotional ergonomics.
- Communities require continuity signals.
- Users SHOULD feel welcomed, oriented, and remembered.
- Usability is architectural.
- Retention MUST emerge from value, continuity, trust, and belonging, not
  from addiction loops.
- GPForum MUST prohibit: manipulative notification systems; artificial
  urgency loops; exploitative dopamine mechanics; dark-pattern engagement
  systems; hidden ranking manipulation; ragebait amplification;
  deliberately compulsive interaction loops.

### 2. Community Lifecycle Model

- GPForum MUST model community participation as a lifecycle.
- Mandatory lifecycle stages, with what each needs:
  - anonymous visitor: readable public-safe pages; clear context; no
    dark-pattern registration pressure; privacy-safe discovery;
  - newcomer: orientation; etiquette visibility; low-friction first
    participation; safe beginner discovery; validation errors that reduce
    anxiety;
  - participant: clear reply and quote flows; notification control;
    bookmarks and continuity; permission-safe feedback;
  - regular: continuity; subscription-aware feeds; profile identity;
    contribution history; personalization;
  - trusted contributor: earned permissions where policy allows; visible
    recognition; explainable trust state; reversible moderation authority
    boundaries;
  - moderator: humane queues; audit-backed actions; escalation flows;
    sustainable workload surfaces;
  - long-term steward: governance continuity; community health visibility;
    archival durability; policy evolution tools.
- GPForum SHOULD support newcomer onboarding flows, contextual help,
  orientation systems, contributor milestones, guided participation, and
  re-entry flows for returning users.

### 3. Social Continuity And Return Experience

- GPForum MUST support: unread tracking; continue-reading flows; reading
  history; resume-thread behavior; stable anchors; notification continuity;
  thread revisit awareness.
- GPForum SHOULD support: continue where you left off; session continuity;
  reading queue; saved threads; contextual reminders; digest summaries;
  return-to-discussion flows.
- Users SHOULD NOT feel lost when returning after time away.
- Continuity systems MUST remain privacy-aware.
- Continuity MUST degrade gracefully.
- Reading history and revisit state MUST NOT become covert surveillance.

### 4. Community Feeds And Discovery

- GPForum MUST support: latest discussions; followed discussions;
  subscription-aware feeds; permission-aware discovery; chronological-safe
  discovery.
- GPForum SHOULD support: trending discussions; recommended discussions;
  related threads; personalized discovery; newcomer-safe discovery;
  low-noise discovery; contextual resurfacing.
- Discovery systems MUST: remain explainable; resist manipulation; remain
  permission-aware; avoid ragebait incentives; avoid opaque behavioral
  ranking.
- Discovery categories: chronological, relevance, personalized, and
  governance-safe discovery.
- Chronological discovery is the baseline.
- Relevance discovery MUST explain its inputs at a human level.
- Personalized discovery MUST remain optional, reversible, privacy-safe, and
  permission-aware.
- Governance-safe discovery MUST respect moderation, privacy, noindex, and
  restricted-content rules.

### 5. Contributor Identity

- GPForum MUST support: public-safe user profiles; participation visibility
  where policy permits; contributor history; stable identity
  representation.
- GPForum SHOULD support: profile cards; contributor badges; earned titles;
  role flair; contribution summaries; optional signatures; profile
  customization; public reputation summaries.
- Contributor identity SHOULD feel meaningful.
- Identity systems MUST remain abuse-resistant.
- Customization MUST remain moderation-aware.
- Profiles MUST never expose private or security-sensitive account state.

### 6. Reputation And Trust UX

- GPForum SHOULD support: trust levels; earned permissions; contributor
  recognition; community reputation; helpful contribution signals;
  participation milestones.
- Reputation is advisory, not sovereign.
- Moderation authority remains authoritative.
- Trust systems MUST remain explainable.
- Hidden behavioral scoring is discouraged.
- Anti-spam systems MUST remain appealable where feasible.
- GPForum MUST prohibit: manipulative social scoring; opaque shadow-ranking;
  exploitative gamification loops; reputation systems that override policy
  or moderation authority.

### 7. Social Interaction Ergonomics

- GPForum MUST support: replies; quotes; stable references; mentions;
  bookmarks.
- GPForum SHOULD support: reactions; lightweight acknowledgements; partial
  quoting; multi-quote; post linking; thread linking; contextual references;
  social acknowledgements.
- Social interactions SHOULD reinforce continuity.
- Lightweight interactions MUST NOT overwhelm discussion quality.
- Reactions and acknowledgements are social signals, not authority systems.

### 8. Thread Experience And Long-Form Reading

- GPForum MUST support: readable layouts; stable navigation; long-thread
  survivability; quote safety; revision awareness; mobile readability.
- GPForum SHOULD support: thread summaries; collapsible quotes; reading
  progress indicators; contextual thread maps; jump-to-unread; compact
  reading mode; reading mode.
- Long discussions SHOULD remain navigable.
- Readability is operationally important. Archival readability matters.
- Pagination MUST remain durable, stable, and keyset-friendly.
- Infinite-scroll addiction traps are prohibited.

### 9. Knowledge And Collective Memory

- GPForum SHOULD support: solved discussions; canonical answers; wiki posts;
  FAQ extraction; curated thread indexes; knowledge-base views; summary
  layers; durable reference threads.
- Discussions may evolve into knowledge. Archival value matters.
- Knowledge extraction MUST remain permission-aware.
- GPForum distinguishes ephemeral discussion, durable knowledge, governance
  records, and historical archives.
- Knowledge systems MUST NOT erase conversational context unless policy
  explicitly requires redaction or moderation.

### 10. Personalization And User Comfort

- GPForum SHOULD support: theme preferences; compact mode; reading
  preferences; notification preferences; timezone-aware rendering;
  accessibility preferences; content density preferences; mute systems;
  bookmark systems.
- Personalization MUST remain privacy-safe.
- Personalization MUST remain reversible.
- Personalization MUST NOT create opaque filter bubbles.
- Personalization MUST NOT compromise permission-aware rendering.

### 11. Community Health And Retention

- GPForum SHOULD support: contributor appreciation; digest systems; healthy
  re-engagement; newcomer assistance; moderator wellness tooling; low-noise
  defaults.
- Retention SHOULD emerge from value.
- Healthy pacing, burnout prevention, and moderator sustainability matter.
- Communities require stewardship.
- GPForum MUST prohibit: outrage amplification; compulsive engagement
  mechanics; intentionally addictive UX loops; retention systems that
  punish leaving or resting.

### 12. Moderator Ergonomics And Community Care

- GPForum MUST support: moderation visibility; report handling;
  audit-backed actions; reversible moderation where feasible.
- GPForum SHOULD support: moderator notes; moderation workflows; triage
  systems; burnout-reduction tooling; escalation flows; community health
  indicators.
- Moderators are caretakers of continuity. Moderation UX affects community
  quality.
- Moderation systems MUST remain humane.
- Moderator tools MUST preserve accessibility, auditability, and emotional
  sustainability.

### 13. Onboarding And Newcomer Experience

- GPForum SHOULD support: welcome flows; contextual onboarding; posting
  guidance; first-post guidance; community etiquette visibility; mentorship
  systems; safe beginner discovery.
- Newcomers SHOULD NOT feel punished by complexity.
- Onboarding SHOULD reduce anxiety.
- Governance SHOULD remain understandable.
- Onboarding MUST NOT become coercive conversion pressure.

### 14. Community Events And Temporal Systems

- GPForum SHOULD support: announcements; seasonal events; temporary
  banners; featured discussions; digest cycles; contributor highlights;
  community milestones.
- Temporal systems MUST NOT compromise archival integrity.
- Event systems MUST remain moderation-safe.
- Temporal content MUST have clear ownership, expiration, auditability
  where policy requires, and graceful removal.

### 15. Social Presence And Realtime Feel

- GPForum SHOULD support: online indicators; typing indicators; reading
  indicators; active-now signals; lightweight collaborative presence.
- Realtime is enhancement only.
- Realtime MUST degrade gracefully.
- Presence systems MUST remain permission-aware.
- Presence MUST NOT become surveillance.
- Presence state is disposable and MUST NOT become authoritative.

### 16. Mobile-First Human Ergonomics

- GPForum MUST support: touch-safe interaction; readable typography;
  responsive thread layouts; low-bandwidth operation; keyboard
  accessibility; reduced-motion compatibility.
- GPForum SHOULD support: PWA behavior; offline drafts; installable app
  behavior; gesture enhancements.
- Mobile users are first-class participants. Accessibility is
  architectural.
- Mobile UX MUST preserve posting, reading, moderation basics, and
  notification control.

### 17. Analytics, Community Health And Explainability

- GPForum SHOULD support: community health metrics; participation metrics;
  retention metrics; moderation workload metrics; onboarding metrics;
  search quality metrics.
- Analytics MUST remain explainable.
- Analytics MUST remain privacy-aware.
- Analytics MUST NOT become covert surveillance.
- Community health metrics MUST support stewardship, not manipulation.

### 18. Federation, Syndication And Community Reach

- GPForum SHOULD support: RSS/Atom; ActivityPub experiments; webmentions;
  digest exports; safe syndication.
- Syndication MUST remain permission-aware.
- Federation MUST remain optional.
- External reach MUST NOT compromise governance.
- External systems MUST NOT become authoritative for GPForum identity,
  moderation, or canonical content.

### 19. Required Updates To Existing Constitutions

- The following constitutions MUST remain aligned: ADR 0054 (frontend);
  ADR 0055 (realtime); ADR 0062 (search); ADR 0065 (community operations);
  ADR 0073 (UX); ADR 0078 (notifications); ADR 0079 (admin console);
  ADR 0080 (content policy); ADR 0082 (SEO and discovery); ADR 0083
  (plugins); ADR 0087 (governance); ADR 0093 (verifiable invariants);
  ADR 0094 (accessibility).
- Future community features MUST define emotional/community implications,
  moderation implications, operational implications, UX implications,
  accessibility implications, and anti-dark-pattern safeguards.

### 20. Mandatory Vs Optional Community Features

- Mandatory MVP posture: readable thread experience; stable anchors; basic
  profiles; replies and quotes; bookmarks or saved state where implemented;
  unread/read continuity; notification preference control;
  permission-aware discovery; moderation visibility;
  accessibility-preserving mobile behavior.
- Strongly recommended: newcomer onboarding; continue-reading; contributor
  milestones; profile cards; related discussions; digest summaries;
  low-noise defaults; moderator wellness tooling.
- Optional advanced: custom badges; trust levels; recommended discussions;
  solved threads; wiki posts; knowledge-base mode; PWA offline drafts;
  ActivityPub experiments.
- Experimental: personalized discovery; community health dashboards; social
  presence indicators; collaborative editing; advanced summaries.
- Experimental systems require ADR review when they affect privacy,
  ranking, moderation, reputation, federation, or retention.

### 21. Incremental Implementation Roadmap

1. Reading and return continuity: stable anchors; unread tracking;
   jump/resume behavior; keyset-friendly long-thread navigation.
2. Contributor identity: public-safe profiles; contribution summaries; role
   flair and moderation-safe identity decoration.
3. Discovery and feeds: latest discussions; followed discussions;
   subscription-aware feeds; permission-aware related threads.
4. Comfort and personalization: theme and density preferences;
   notification preferences; mutes; saved reading state.
5. Stewardship and health: onboarding; community digests; moderator
   workload visibility; healthy re-engagement.
6. Advanced knowledge systems: solved threads; curated indexes; wiki posts;
   knowledge-base views.

The correct GPForum community architecture is not the one that maximizes
daily clicks. It is the one that helps people return, understand,
contribute, care for each other, preserve knowledge, and leave without
being manipulated.

## Consequences

- Product features are judged by continuity, trust, and explainability,
  not engagement volume; ADR 0093 treats dark-pattern retention, opaque
  ranking, hostile UX, and continuity breakage in core workflows as
  architecture failures.
- Discovery, reputation, presence, and analytics stay derived, explainable,
  permission-aware, and non-authoritative, which rules out opaque
  behavioral ranking and hidden scoring.
- Keyset pagination, stable anchors, and unread tracking are product
  requirements, not only performance choices.
- Continuity and analytics features carry privacy review so they do not
  become surveillance.
- Experimental features touching privacy, ranking, moderation, reputation,
  federation, or retention need an ADR before they ship.

## Alignment

- Related ADRs: ADR 0065 (community operations), ADR 0073 (UX), ADR 0093,
  ADR 0094, ADR 0096, ADR 0101 (search, feed, and syndication retrieval),
  and the constitutions listed in section 19.
- Existing ADRs: 0010 (moderation workflow), 0015 (attachment and
  notification workflows), 0024 (forum view models), 0030 (discovery
  access).
- Code: `lib/GPForum/Service/Forum/ReadState.pm`,
  `lib/GPForum/Service/Forum/PageWindow.pm`,
  `lib/GPForum/Service/Community/`, `lib/GPForum/Service/Discovery/`,
  `lib/GPForum/Service/Identity/ProfileReader.pm`,
  `lib/GPForum/Service/Notification/`.
- Docs: `docs/PRODUCT_FLOWS.md`, `docs/MVP.md`.
- Tests: `t/21-forum-pagination.t`, `t/24-advanced-community.t`,
  `t/30-public-discovery.t`, `t/41-thread-read-state.t`,
  `t/42-profile-reader.t`, `t/17-notifications.t`,
  `t/09-prompt-alignment.t`.
