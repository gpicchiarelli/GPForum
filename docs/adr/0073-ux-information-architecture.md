# ADR 0073: UX, Information Architecture and Interface Behavior

## Status

Accepted. Converted on 2026-09-19 from `prompt/25.txt` ("GPForum - UX,
Information Architecture & Interface Behavior Constitution"); this ADR
replaces the prompt as the binding source.

## Context

GPForum is a reading- and writing-centred discussion tool. Product and
frontend work need one contract for the user experience structure,
navigation model, page inventory, interface states, accessibility
expectations and interaction rules. The rules are mandatory for frontend and
product implementation and govern the SSR presentation layer of the forum,
identity, notification, moderation and admin bounded contexts.

## Decision

### Cross-ADR alignment

- ADR 0094 (accessibility): UX correctness includes accessibility
  correctness. All navigation, composer, thread reading, notification,
  moderation, mobile and settings workflows MUST meet WCAG 2.2 AA targets,
  preserve keyboard access, provide visible focus, expose semantic state, and
  avoid inaccessible custom widgets or JavaScript-only core interactions.
- ADR 0095 (community lifecycle): UX correctness includes emotional
  usability and social continuity. Users SHOULD feel welcomed, oriented and
  remembered. Return experience, unread state, contributor identity,
  long-form readability, newcomer guidance and healthy re-engagement MUST
  reject addictive loops, artificial urgency, opaque ranking and exploitative
  gamification.

### UX philosophy

GPForum MUST feel like a serious, fast, readable discussion tool.

The interface MUST prioritize: reading; writing; navigation; moderation
clarity; low cognitive load; accessibility; operational transparency where
appropriate.

The interface MUST avoid: gamified clutter; dark patterns; hidden
destructive actions; JavaScript-only core workflows; unreadable dense
layouts; ambiguous moderation states.

### Primary navigation

- Primary navigation SHOULD include: home; spaces; categories; search;
  notifications; profile/settings; moderation queue when authorized; admin
  when authorized.
- Navigation MUST be permission-aware.
- Unauthorized controls SHOULD not render, but server authorization remains
  mandatory.

### Core pages

- Home page: shows recent visible activity; highlights spaces/categories;
  supports logged-out reading where policy allows.
- Space page: shows the categories in the space; shows recent activity;
  explains archived/restricted state safely.
- Category page: lists threads; supports pagination; exposes the new thread
  action when authorized; shows category state.
- Thread page: shows title, posts and the reply composer where authorized;
  shows locked/archived state; supports pagination; supports moderation
  controls for staff.
- Profile page: shows public-safe user details; shows activity where policy
  allows; hides sensitive account/security details.
- Notifications page: shows the notification list; supports mark read;
  respects preferences.
- Moderation queue: shows reports and quarantined content; supports scoped
  actions; shows audit-relevant context.
- Admin dashboard: shows operational controls; avoids mixing routine
  moderation with infrastructure administration unless necessary.

### Composer UX

The composer MUST: preserve text on validation errors; show safe validation
messages; support preview where feasible; support attachment state where
implemented; clearly indicate locked or archived targets.

The composer MUST NOT: silently discard input; imply success before
persistence; allow unsafe HTML preview.

### Content states

- The UI MUST represent: normal; edited; hidden; deleted; quarantined;
  locked; archived; unread; subscribed; muted.
- State labels MUST be concise and safe.
- Public users MUST NOT see internal moderation notes.

### Moderation UX

- Moderation controls MUST be: scoped; explicit; confirmation-aware for
  destructive actions; reason-aware where policy requires; audit-aligned.
- Moderators SHOULD see: target context; prior moderation history; report
  reason; available actions; reversal state where applicable.

### Accessibility

- The interface MUST support: keyboard navigation; readable focus states;
  semantic HTML; sufficient contrast; form labels; error association;
  responsive layouts; reduced-motion compatibility where animation exists.
- Core workflows MUST remain usable without heavy JavaScript.

### Internationalization

- UI text MUST be localizable.
- Time rendering MUST be timezone-aware.
- Pluralization MUST be handled explicitly.
- Hardcoded language assumptions MUST be avoided in templates.

### Empty and error states

- Empty states MUST be useful and short.
- Error states MUST: explain what the user can do next; avoid internal
  details; preserve user input where possible; include a correlation id for
  support where applicable.

### Realtime UX

- Realtime updates SHOULD be subtle.
- Realtime MUST NOT cause: layout jumps during reading; lost composer input;
  duplicated posts; inaccessible state changes.
- When realtime fails, the UI SHOULD degrade to refresh-based behavior.

## Consequences

- Reading and writing stay usable without JavaScript, so SSR remains the
  primary delivery path and realtime is an enhancement that may fail
  silently to refresh-based behavior.
- Every new page or content state must be designed for all listed states,
  permission-aware navigation, localization and accessibility, which raises
  the cost of UI changes but keeps moderation state unambiguous.
- Moderation and admin surfaces carry confirmation, reason and audit
  context requirements that shape their templates and view models.

## Alignment

- ADRs: 0094 and 0095 (cross-alignment), 0054 (frontend and themes), 0065
  (community operations), 0072 (HTTP routes); 0001 (SSR UI system), 0003
  (SSR view models), 0004 (semantic templates), 0021 (i18n boundaries), 0024
  (forum view models).
- Code: `templates/`, `lib/GPForum/View/`, `lib/GPForum/ViewModel/`,
  `lib/GPForum/Service/I18N/`, `themes/`.
- Tests: `t/35-forum-accessible-ssr.t`, `t/64-i18n.t`,
  `t/65-accessible-theme.t`, `t/67-ui-system.t`, `t/117-i18n-boundaries.t`.
- Docs: `docs/UI_SYSTEM.md`, `docs/UI_ACCESSIBILITY.md`,
  `docs/ui/accessibility.md`, `docs/ui/design-system.md`, `docs/i18n.md`,
  `docs/PRODUCT_FLOWS.md`, `THEMING.md`.
