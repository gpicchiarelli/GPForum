# ADR 0094: Accessibility Engineering Constitution

## Status

Accepted. Converted on 2026-09-19 from `prompt/46.txt` ("GPForum -
Accessibility Engineering Constitution"); this ADR replaces the prompt as the
binding source.

## Context

This constitution defines the mandatory accessibility engineering doctrine,
WCAG enforcement rules, semantic rendering requirements, keyboard-first
interaction contract, assistive technology compatibility model, theme safety
rules, plugin accessibility governance, and accessibility-aware operational
discipline of GPForum. It is mandatory.

Accessibility is a non-negotiable architectural invariant of GPForum. It is
not visual polish. Accessibility is operational correctness, usability
correctness, governance correctness, participation equality, long-term
maintainability, and community continuity.

It governs every user-facing surface: SSR templates, themes, the composer,
thread and discussion pages, notifications and realtime, mobile and touch,
moderation and admin tooling, and plugin-rendered UI.

This constitution preserves PostgreSQL-first architecture, Perl-first
implementation, SSR-first rendering, explicit governance, operational
simplicity, rebuildable projections, auditability, moderation authority,
graceful degradation, anti-dark-pattern philosophy, and durable public
discussion.

This constitution rejects accessibility as optional enhancement,
JavaScript-only interaction, inaccessible custom widgets, keyboard-hostile
interaction, hidden focus behavior, inaccessible themes, inaccessible plugin
rendering, and accessibility regressions without review.

## Decision

### 1. Accessibility Philosophy

- Accessibility is architectural, a release requirement, a governance
  requirement, part of trust, and part of long-term usability.
- Accessibility regressions are operational regressions.
- Disabled users are first-class participants.
- Keyboard users are first-class participants.
- Screen-reader users are first-class participants.
- Low-vision users are first-class participants.
- Low-bandwidth users are first-class participants.
- Assistive technologies are supported interaction models, not edge cases.
- Graceful degradation is mandatory. Semantic rendering and accessible SSR
  matter.
- Core forum participation MUST remain possible without JavaScript where
  technically feasible.
- When JavaScript enhances interaction, it MUST preserve semantic meaning,
  keyboard access, focus order, and assistive technology compatibility.

### 2. WCAG Targets

- All user-facing GPForum interfaces MUST target WCAG 2.2 AA compliance.
- GPForum SHOULD target WCAG 2.2 AAA where practical and where doing so does
  not harm clarity, usability, performance, or moderation safety.
- Accessibility violations are release-blocking when critical.
- Exceptions require documented ADR review.

Violation severity:

- Critical violations:
  - blocked keyboard access to a core workflow;
  - screen-reader inability to use a core workflow;
  - missing accessible name on a critical control;
  - inaccessible authentication, posting, search, moderation, or
    notification flow;
  - focus trap preventing escape;
  - content or controls hidden from assistive technology incorrectly;
  - unsafe flashing or motion hazard;
  - contrast failure that prevents reading or operation.
- Major violations:
  - confusing heading hierarchy on important pages;
  - missing landmark structure on major routes;
  - incomplete form error association;
  - degraded keyboard shortcuts without fallback;
  - non-critical custom widget accessibility gaps;
  - mobile touch targets that impair ordinary use.
- Minor violations: small semantic inconsistencies; redundant accessible
  descriptions; non-blocking focus-order roughness; cosmetic spacing issues
  that do not block use.
- Advisory improvements: AAA contrast improvements; extra screen-reader
  navigation aids; advanced keyboard shortcuts; personalization
  enhancements; alternative reading-density modes.

### 3. Semantic HTML Doctrine

- All server-rendered pages MUST use semantic HTML.
- GPForum MUST provide: landmarks; logical heading hierarchy; accessible
  forms; accessible tables; semantic buttons; semantic links; accessible
  lists; accessible navigation regions; accessible status regions where
  needed.
- The platform MUST prohibit:
  - clickable divs without keyboard behavior;
  - placeholder-only forms;
  - icon-only controls without accessible names;
  - broken heading order that impairs navigation;
  - hidden interactive focus;
  - custom controls that do not expose role, name, state, and keyboard
    behavior;
  - ARIA used to cover broken semantics when native semantics are
    available.
- Semantic HTML is preferred over ARIA.
- ARIA supplements semantics; it does not replace them.
- Templates MUST render meaningful structure before progressive
  enhancement.
- Permission-aware rendering MUST remain semantic: hidden controls MUST not
  create orphaned labels, broken descriptions, or confusing navigation.

### 4. Keyboard-First Interaction

- All interactive UI MUST support: full keyboard navigation; visible focus
  indicators; logical focus order; escape behavior where appropriate;
  predictable tab navigation; keyboard activation for all controls.
- GPForum MUST prohibit: inaccessible focus traps; invisible focus;
  pointer-only interaction; hover-only controls; unreachable dialogs;
  keyboard traps without escape; controls whose focus order differs
  materially from visual and semantic order.
- GPForum SHOULD support: skip links; keyboard shortcuts; quick navigation
  patterns; jump-to-unread; post and thread navigation shortcuts; composer
  shortcuts with discoverable help.
- Keyboard shortcuts MUST NOT conflict with text entry, screen-reader
  navigation, or browser/platform conventions without explicit opt-in.

### 5. Screen Reader Compatibility

- GPForum MUST provide: accessible names; accessible descriptions;
  accessible states; proper labels; safe live-region behavior; dialog
  semantics; menu semantics where appropriate; form error relationships;
  status messages that are programmatically determinable.
- Realtime updates MUST remain assistive-safe.
- Notifications MUST avoid live-region spam.
- Dynamic updates MUST remain understandable.
- GPForum SHOULD support: screen-reader-friendly navigation aids;
  contextual announcements; accessible status indicators; summaries before
  dense operational tables; user-controlled verbosity for realtime and
  notification announcements.
- Screen-reader users MUST be able to complete core workflows:
  registration; login; browsing categories; reading threads; composing
  posts; searching; reading notifications; reporting content; staff
  moderation where authorized.

### 6. Color, Contrast And Visual Accessibility

- GPForum MUST provide: WCAG AA contrast minimums; visible focus
  indicators; non-color affordances; scalable typography; readable spacing;
  reduced visual hostility; readable error and moderation states.
- GPForum MUST prohibit: color-only state signaling; inaccessible contrast
  themes; hidden focus states; unreadable compact modes; text that cannot
  scale without breaking core workflows; moderation states that rely only
  on color.
- GPForum SHOULD support: high contrast modes; low motion modes;
  dyslexia-friendly options; user typography scaling; density preferences
  that preserve readability.
- All state indicators SHOULD combine visual, textual, and semantic
  affordances.

### 7. Motion And Animation Policy

- GPForum MUST respect `prefers-reduced-motion`.
- Animations MUST: remain optional; avoid conveying essential meaning; avoid
  disorienting transitions; avoid interfering with reading or composing;
  remain bounded in duration and frequency.
- GPForum MUST prohibit: flashing hazardous animations; excessive motion
  dependency; accessibility-hostile transitions; animation that causes lost
  focus or lost reading position; motion used to manipulate attention.
- Realtime changes SHOULD prefer calm indicators over disruptive movement.

### 8. Composer Accessibility

- The composer MUST support: keyboard-only operation; accessible toolbar
  controls; labelled inputs; accessible validation; accessible preview
  rendering; safe markdown assistance; screen-reader-safe formatting
  behavior; draft recovery without inaccessible modal traps; attachment
  insertion with accessible labels and states.
- The composer SHOULD support: accessible markdown shortcuts; accessible
  attachment insertion; accessible emoji selection; accessible code block
  insertion; accessible quote and multi-quote workflows;
  keyboard-discoverable formatting help.
- Preview rendering MUST remain semantically readable.
- Formatting helpers MUST remain accessible.
- Toolbar controls MUST expose names, pressed/expanded states where
  relevant, and keyboard activation behavior.
- Validation errors MUST preserve user input and programmatically associate
  messages with the relevant fields.
- Attachment upload status MUST be visible, textual, and screen-reader
  safe.

### 9. Thread And Discussion Accessibility

- Thread pages MUST support: semantic post structure; accessible quote
  rendering; accessible pagination; accessible navigation anchors; stable
  post references; readable author and timestamp metadata; accessible edit,
  moderation, report, quote, and reply controls.
- GPForum SHOULD support: jump-to-unread accessibility; accessible reading
  progress; accessible thread summaries; keyboard thread traversal;
  collapsible quotes with correct expanded state; skip-to-composer and
  skip-to-posts links.
- Long-form reading ergonomics and archival readability matter.
- Post anchors MUST remain stable and meaningful.
- Pagination MUST remain keyset-based and accessible.
- Infinite-scroll traps are prohibited.

### 10. Notification And Realtime Accessibility

- Realtime systems MUST: degrade gracefully; avoid disruptive
  announcements; remain understandable with assistive technology; preserve
  focus and reading position; avoid duplicate announcements after
  reconnect.
- Notification systems MUST: expose accessible text; expose semantic state;
  avoid inaccessible badge-only signaling; support read/unread state in text
  and semantics; respect muted and permission-safe behavior.
- GPForum SHOULD support: user-controlled notification verbosity; reduced
  realtime interruption modes; accessible digest summaries; accessible
  notification grouping.
- Realtime is enhancement only.
- Core forum usage MUST NOT depend on websocket availability.

### 11. Mobile And Touch Accessibility

- GPForum MUST provide: touch-safe targets; responsive layouts; zoom
  compatibility; orientation safety; low-bandwidth friendliness; keyboard
  accessibility on mobile and tablet devices; readable typography under
  small viewport constraints.
- GPForum SHOULD support: gesture alternatives; accessible mobile
  navigation; installable PWA accessibility; offline drafts where feasible;
  reduced-data rendering options.
- Mobile users are first-class participants.
- Accessibility is architectural on mobile, not a desktop-only property.

### 12. Admin And Moderation Accessibility

- Moderation and admin systems MUST support: keyboard operation; accessible
  queues; accessible dialogs; accessible filters; accessible audit views;
  screen-reader compatibility; accessible bulk actions where bulk actions
  exist; accessible confirmation and reversal flows.
- Moderation effectiveness depends on accessibility. Inaccessible
  moderation tooling is operationally unsafe.
- Staff workflows MUST preserve: focus order; semantic table/list
  structure; accessible status; clear action labels; audit context;
  non-color-only severity and state indicators.
- Emergency controls MUST remain accessible under stress.

### 13. Theme Accessibility Governance

- Themes MUST: preserve semantic rendering; preserve focus visibility;
  preserve contrast requirements; preserve landmark visibility; preserve
  keyboard accessibility; preserve reduced-motion behavior; preserve
  accessible names and descriptions.
- Themes MUST NOT: remove accessibility affordances; hide semantic
  structure; reduce contrast below policy; remove accessible names; break
  focus order; make compact modes unreadable; make dark/light modes unsafe.
- GPForum SHOULD support: accessibility-safe design tokens; contrast
  validation; reduced-motion theme support; accessibility metadata in theme
  manifests; high-contrast theme variants.
- Themes cannot degrade below WCAG 2.2 AA.
- Theme activation SHOULD be testable against representative routes.

### 14. Plugin Accessibility Governance

- Plugins MUST: preserve semantic rendering; preserve keyboard
  accessibility; preserve screen-reader compatibility; expose accessible
  names and states; respect reduced-motion and theme constraints; provide
  accessible error states.
- Plugins MUST NOT: inject inaccessible widgets; bypass semantic rendering;
  break keyboard traversal; break assistive compatibility; hide focus;
  introduce JavaScript-only core workflow behavior.
- GPForum SHOULD support: plugin accessibility capability declarations;
  accessibility validation hooks; plugin accessibility linting; plugin
  accessibility metadata; plugin quarantine or disablement for critical
  accessibility failures.
- Plugin accessibility violations are plugin contract violations.

### 15. Accessibility Testing And CI

- Automated accessibility checks are mandatory.
- GPForum SHOULD support: axe-core; pa11y; HTML validation; contrast
  validation; keyboard smoke tests; template semantic checks; browser
  workflow checks where feasible.
- Critical routes MUST be tested: home; category; thread; composer; search;
  login/register; notifications; moderation; admin dashboard.
- Accessibility checks are release gates.
- Accessibility regressions require explicit review.
- Automated tools are necessary but insufficient. Manual keyboard and
  assistive technology review SHOULD be used for high-risk interaction
  patterns, custom widgets, moderation workflows, and composer changes.

### 16. Accessibility Observability

- GPForum SHOULD support: accessibility audit reporting; accessibility CI
  metrics; theme accessibility validation; plugin accessibility reporting;
  route-level accessibility status; known-exception dashboards.
- Accessibility status MUST remain observable.
- Accessibility debt MUST remain measurable.
- Accessibility metrics MUST be used for release and maintenance decisions,
  not for performative reporting.

### 17. Accessibility Documentation

- GPForum MUST document: accessibility targets; semantic rendering rules;
  keyboard interaction rules; theme constraints; plugin constraints; testing
  procedures; known exceptions; ADRs for exceptions; mitigation plans;
  review dates.
- Accessibility exceptions require ADRs. Exceptions require mitigation
  plans. Exceptions require review dates.
- Documentation MUST distinguish: implemented guarantees; planned
  improvements; known exceptions; accepted limitations; experimental
  enhancements.

### 18. Required Updates To Existing Constitutions

- The following constitutions MUST remain aligned with this document:
  ADR 0054 (frontend and themes); ADR 0055 (realtime); ADR 0057
  (authorization and moderation governance); ADR 0059 (CI/CD); ADR 0062
  (search); ADR 0065 (community operations); ADR 0072 (HTTP workflows and
  composer routes); ADR 0073 (UX); ADR 0078 (notifications and email);
  ADR 0079 (admin console); ADR 0083 (plugins); ADR 0084 (testing);
  ADR 0085 (API and websocket schemas); ADR 0087 (prompt governance, now ADR
  governance); ADR 0089 (profiling and coverage); ADR 0093 (verifiable
  engineering invariants).
- Any future user-facing workflow, theme system, plugin hook, custom widget,
  notification surface, moderation tool, composer feature, or realtime
  interaction MUST define accessibility implications and test expectations.

### 19. Mandatory Vs Optional Accessibility Controls

- Mandatory controls: WCAG 2.2 AA target for user-facing interfaces;
  semantic server-rendered HTML; keyboard access for all interactive
  controls; visible focus; accessible form labels and errors; accessible
  names for icon controls; screen-reader-safe core workflows; reduced-motion
  respect; accessible theme constraints; accessible plugin constraints;
  accessibility checks as release gates; ADRs for critical exceptions.
- Strongly recommended controls: axe-core or pa11y route checks; keyboard
  smoke tests; contrast validation; HTML validation; high-contrast theme
  validation; plugin accessibility linting; manual screen-reader review for
  complex interactions; route-level accessibility status reporting.
- Optional advanced controls: WCAG 2.2 AAA improvements; dyslexia-friendly
  typography; user-controlled notification verbosity; advanced keyboard
  shortcuts; PWA accessibility enhancements; offline draft accessibility;
  accessibility dashboarding.
- Experimental controls: automated semantic template linting; accessibility
  regression screenshots; plugin accessibility scorecards; route
  accessibility budgets; assistive-technology scripted checks.

### 20. ADR Recommendations

ADR approval SHOULD be required for:

- any critical accessibility exception;
- custom widgets replacing native controls;
- JavaScript-required interaction in a core workflow;
- theme features that affect contrast, focus, motion, or semantic
  structure;
- plugin hooks that render interactive UI;
- realtime live-region strategies;
- complex moderation/admin interaction patterns;
- composer editor technology choices;
- accessibility tradeoffs between dense operational UI and readability;
- persistent known WCAG AA gaps.

### 21. Incremental Adoption Roadmap

1. Semantic baseline: define route landmarks; ensure labels, headings,
   buttons, links, and forms are semantic; add visible focus tokens; add
   skip links.
2. Workflow coverage: add accessibility checks for home, category, thread,
   composer, search, login/register, notifications, moderation, and admin
   surfaces; add keyboard smoke tests for core workflows.
3. Theme and plugin governance: add theme accessibility metadata; add
   contrast validation; add plugin accessibility capability declarations.
4. Realtime and notification refinement: add user-controlled realtime
   announcement verbosity; add accessible notification grouping; verify
   live-region behavior.
5. Advanced comfort: add high-contrast options; add density/typography
   preferences; add reduced-data and low-motion refinements.

### 22. MVP Vs Advanced Accessibility Rollout

- MVP accessibility MUST include: semantic SSR; keyboard-operable
  navigation; accessible forms and validation; visible focus; WCAG AA
  contrast; accessible category/thread/search/composer/login routes;
  accessible moderation basics; reduced-motion support; no JavaScript-only
  core workflows.
- Advanced accessibility SHOULD include: high-contrast modes; advanced
  keyboard shortcuts; screen-reader navigation aids; user-controlled
  notification verbosity; theme accessibility validation; plugin
  accessibility linting; PWA accessibility; offline draft accessibility.
- Experimental accessibility MAY include: automated assistive-technology
  simulation; accessibility budgets; plugin accessibility scorecards;
  per-user interaction-density adaptations.
- The correct posture is not late accommodation; it is to make
  participation equality an engineering invariant from the beginning.

## Consequences

- Accessibility failures are correctness failures: critical violations block
  releases, and ADR 0093 treats WCAG-critical regressions, inaccessible core
  workflows, inaccessible plugin UI, and inaccessible themes as invariant
  violations.
- SSR-first semantic templates stay the primary rendering path; JavaScript
  and realtime can only enhance, which limits SPA-style widget work.
- Themes and plugins take on accessibility contracts; theme activation and
  plugin UI need validation before they ship.
- Every new user-facing workflow carries accessibility tests and
  documentation work; exceptions need an ADR, mitigation plan, and review
  date.

## Alignment

- Related ADRs: ADR 0001 (SSR UI system), ADR 0003 (SSR view models),
  ADR 0004 (semantic template architecture), ADR 0093, ADR 0095, ADR 0096,
  and the constitutions listed in section 18.
- Docs: `docs/ui/accessibility.md`, `docs/UI_ACCESSIBILITY.md`,
  `docs/UI_SYSTEM.md`, `docs/ui/design-system.md`, `THEMING.md`.
- Code and templates: `templates/`, `themes/`,
  `lib/GPForum/Theme/Registry.pm`, `lib/GPForum/ViewModel/`.
- Tests: `t/35-forum-accessible-ssr.t`, `t/65-accessible-theme.t`,
  `t/67-ui-system.t`, `t/79-theme-preference.t`, `t/09-prompt-alignment.t`.
