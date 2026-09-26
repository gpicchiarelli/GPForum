# ADR 0102: Effective Visibility

## Status

Accepted.

## Context

Migration `003_forum_projection.sql` gives spaces, categories, threads, and
posts a `visibility` column (`public`, `members`, `private`), but only the
thread and post columns were ever read, and only as a "thread-only public"
filter. An external review (task 3, security and privacy) confirmed:

- no reader queried `spaces`; category visibility was never checked, so a
  private category was listed on `/categories`, the home page and the
  new-thread form, rendered on `/c/:id` with HTTP 200, and stored in the
  public HTTP cache;
- a `public` thread inside a private category was readable, listed, searched,
  cached, and exported through the sitemap, the Atom feed, OpenGraph metadata,
  and profile activity;
- every non-public thread returned 404 to everyone, its author included;
- thread creation accepted any requested visibility (default `public`)
  regardless of the category, and replies copied the thread's own column;
- search indexed every row with `permission_scope = visibility`, showed
  anonymous users public documents from private categories, showed every
  authenticated (even suspended) user all `members` documents, filtered ACLs
  after `LIMIT` (short pages plus N+1 queries), and returned full bodies in
  JSON;
- notification permission checks were never wired, and mentions were
  recorded and notified unconditionally, leaking thread and post ids plus the
  actor to users who cannot read the source;
- `PermissionGate` matched a permission by `(resource_type, action)` and
  ignored the binding scope, and no read permission for categories existed;
- realtime thread subscriptions ignored the space, treated `members` like
  `private`, relied on the never-written `resource_acl` table, and broadcasts
  never re-checked access;
- attachment downloads only checked the linked post, and a private target
  without an author was treated as readable by anonymous viewers;
- the public HTTP cache decided cacheability from the request alone (no
  session user), never from what the page contained.

Prompt 52 section 5 requires visibility to propagate through every read,
derived, and public surface, and to fail closed when a surface cannot prove
content is renderable to the actor. Prompt 53 section 15 repeats this for
retrieval surfaces.

## Decision

### Effective visibility

The **effective visibility** of a resource is the most restrictive visibility
among its space, its category, its thread, and (for posts) the post itself,
ordered `public` < `members` < `private`. A missing or unknown value counts as
`private`. `GPForum::Service::Forum::Visibility` owns the ordering, the
"most restrictive" rule, and the SQL condition builders; it has no schema
access.

### Viewers

`GPForum::Service::Forum::ViewerResolver` turns a session user id into a
`GPForum::Service::Forum::Viewer`, once per HTTP request (the
`gp_forum_viewer` helper memoizes it in the stash):

- **anonymous**: no session user;
- **non-participating account**: a session user whose row is missing,
  deleted, in `suspended` status, or under an active `suspensions` row. It is
  treated exactly like an anonymous viewer (public content only);
- **member**: any other signed-in account. This deliberately matches
  `SuspensionStore::can_participate`, the gate that already lets `active` and
  `pending` (not yet e-mail-verified) accounts sign in and post. GPForum never
  moves a verified account from `pending` to `active`, so requiring the
  literal `active` status would lock every registered user out of `members`
  content; the resolver is the single place to tighten this later;
- **grant holder**: a member holding `category.read` through
  `PermissionGate` for a scope (see below).

Resolution failures (database errors, malformed ids) yield a non-member
viewer and are logged: failure means less exposure, never more.

### Readability rule

A viewer can read a resource when none of the space, category, thread, or
post is deleted, the thread's moderation state is `visible` or `locked`, the
post's is `visible`, and every level's visibility is allowed:

| Level visibility | Allowed for                                              |
|------------------|----------------------------------------------------------|
| `public`         | everyone                                                 |
| `members`        | members                                                  |
| `private`        | members holding `category.read` for the resource's category, its space, or globally |

Because "allowed" is monotone in the ordering, checking every level equals
checking the effective visibility. Authors get a narrow override:

- a member can read a thread they authored even when the thread's *own*
  visibility would deny them, and a post they authored even when the post's
  own visibility would deny them;
- the author of a `private` thread can read `private` replies in it (replies
  inherit the thread's visibility, so this keeps a private thread usable by
  its author);
- the override never lifts a space or category restriction, never applies to
  deleted or moderated content, and never applies to non-participating
  accounts. Lifting containers would expose other people's replies to a user
  whose category access was revoked.

### Permission model

- New permission `category.read` (`resource_type = 'category'`,
  `action = 'read'`), added to the bootstrap owner role, so the operator
  bound through `gpforum-admin-bootstrap` (a global binding) can read private
  content. Moderator or member roles only receive it through an explicit
  admin grant.
- `PermissionGate::scoped_grants` returns the scopes an actor holds a
  permission for, from active (`revoked_at IS NULL`) bindings:
  `resource_type = 'global'` with no `resource_id`/`space_id` is global;
  `resource_type = 'space'` covers the space in `resource_id` (or `space_id`);
  `resource_type = 'category'` covers the category in `resource_id`. Any other
  binding shape grants nothing.
- `PermissionGate::allowed` accepts an optional `scope`
  (`{ category_id, space_id }`) and then only counts bindings covering that
  scope. Unscoped calls (admin console, moderation, privacy, realtime
  privileged queues) keep their previous behavior; see Consequences.
- `resource_acl`, `permission_grants`, and `effective_permissions` stay
  unused. Realtime and search no longer consult `resource_acl`.

### Enforcement

Filtering happens in SQL through joins to `categories` and `spaces` (every
joined column qualified), before `LIMIT`, so keyset pages stay full and no
per-row permission queries run.

| Surface | Enforcement |
|---------|-------------|
| `/categories`, home categories, new-thread select | `CategoryReader` joins `space`, applies space and category levels for the viewer; only anonymous lists use the reader cache |
| `/c/:id` | `find_category` with the viewer, then thread list with the viewer |
| `/`, `/c/:id` thread lists | `ThreadReader` joins `category -> space`, applies every level |
| `/t/:id`, bookmark/subscribe/report/read-marker targets | `ThreadDetailReader::find_thread` with the viewer |
| posts on `/t/:id`, `find_visible_post` | `PostReader` joins `thread -> category -> space` |
| `/u/:username` | public-only for every viewer (anonymous rules), counts included |
| search, autocomplete (HTML and JSON) | index-time effective visibility plus query-time join to live category/space rows; JSON results carry the snippet, not the body |
| sitemap, Atom feed | anonymous viewer in SQL, builders also require `effective_visibility = public` |
| metadata / OpenGraph | `index,follow` and OpenGraph only when the thread's effective visibility is public, otherwise `noindex,nofollow` |
| notifications | created only when the recipient can read the source (public sources take a one-query fast path); inbox pages and unread counts only include readable sources |
| mentions | not recorded (skip reason `source_not_readable`) nor notified for users who cannot read the source; mention lists only include readable sources |
| personal feed, bookmarks | thread/post targets filtered through readable-id subqueries |
| realtime thread channels | subscription uses the viewer rules (space included, members vs private); broadcasts to non-public threads re-authorize each subscribed user |
| attachment downloads | linked post/thread loaded through the viewer-aware readable query (post, thread, category, space, moderation, deletion); profile and unlinked files stay owner-only |
| public HTTP cache | only stores or serves a page when every row on it is effectively public |

### Write path

`PostingWorkflow` resolves the author as a viewer (reusing the request viewer
when it is the same user) and validates visibility in the service layer:

- thread creation requires a category the author can read (otherwise
  `not_found`); an empty visibility inherits the category's effective
  visibility (space and category); a broader one is rejected by
  `ThreadComposer` as `visibility is broader than its category`;
- reply creation requires a thread the author can read; an empty visibility
  inherits the thread's effective visibility (space, category, thread); a
  broader one is rejected by `PostComposer`;
- the new-thread form defaults to "inherit from the category", and the reply
  form submits the thread's effective visibility.

### Public HTTP cache

`Web::PublicHttpCache` stores or serves an entry only when the request is
anonymous (unchanged) **and** the controller declares the page's effective
visibility as `public`, computed by `Visibility::page_visibility` over every
row rendered (missing values count as private). Anything else renders
uncached with `Cache-Control: private, no-store`. The cache key gains a
fingerprint of the rendered rows' ids and effective visibility, so an entry
stored while a row was public is never served once the visible set changes.
Key and tag design is otherwise unchanged; a later task owns it.

## Consequences

- Private and members-only spaces and categories now actually hide their
  content; authors can read their own non-public threads; grant holders can
  read private categories.
- Authenticated requests pay up to three extra indexed queries (user,
  active suspension, `category.read` bindings) once per request; anonymous
  requests pay none. Reader queries gain two primary-key joins on small
  tables. Notification and mention creation add one query per recipient for
  public sources, a viewer resolution plus one query for non-public ones.
- Broadcasts to non-public threads re-authorize every subscribed user;
  public threads cost one query per broadcast.
- Profiles, sitemap, and feed never show non-public content, even to users
  who could read it elsewhere.
- Existing search documents keep their old `visibility` until reindexed, but
  the query-time join already applies current category and space
  visibility; a stale document can only be *more* restrictive than the
  truth at the thread/post level after a visibility broadening.

### Anti-leak analysis

Every surface in the enforcement table filters in SQL or re-checks canonical
rows at read time; derived rows (search documents, notifications, mentions,
feed items, bookmarks, cache entries) are never trusted as proof of access.
Unknown visibility values, missing joins, resolver failures, and missing
`effective_visibility` columns all fail closed. Denied reads answer 404, so
existence is not confirmed.

### Replay impact

No event, audit, or outbox shape changes. Search documents, notifications,
and mentions rebuilt by replay apply the same rules at write and read time,
so a replay cannot widen access. No migration is required: the new
permission row is created by `gpforum-admin-bootstrap` (idempotent) or by
admins through the existing catalog.

### Required implementation review (prompt 52 section 20)

1. Canonical truth: `spaces`, `categories`, `threads`, `posts`,
   `role_bindings`, `users`, `suspensions`.
2. Permissions: `category.read` scoped global, space, or category.
3. Visibility: effective visibility as defined above.
4. Moderation: threads `visible`/`locked`, posts `visible`; deleted rows
   never readable.
5. Events: unchanged. 6. Audit: unchanged.
7. Projections: search documents store effective visibility at index time.
8. Cache: public HTTP cache restricted to effectively public pages; the
   category reader cache only serves anonymous lists.
9. Leaks: see the anti-leak analysis and the remaining risks.
10. Replay: see replay impact.

### Remaining risks

- Unscoped `PermissionGate::allowed` still accepts a binding of any scope for
  admin, moderation, and privacy checks (the benchmark seed binds roles per
  space). Making those checks scope-aware changes moderation authority and
  needs its own decision.
- There is no admin workflow that changes space or category visibility yet,
  so no `visibility_version`/`permission_version` bumps, visibility events, or
  cache purges exist for it. Until the cache task lands, a *list* page cached
  while an item was public may still be served for up to its TTL if the
  visible set on that page happens to be identical.
- Moderation queues and privacy exports are out of scope and still show
  reported or requested content to authorized staff.
- `pending` accounts count as members (see Viewers).

### Repository note

- Implemented in stages (quality program 2.8). **Stage 1, on `main`
  2026-09-26:** `GPForum::Service::Forum::Visibility`, `::Viewer` and
  `::ViewerResolver` (one query per signed-in request), the `gp_forum_viewer`
  helper, the `category.read` permission (granted by `gpforum-admin-bootstrap`),
  and the viewer-aware `CategoryReader` (lists and `find_category`),
  `ThreadReader` (category lists and the latest-threads list),
  `ThreadDetailReader::find_thread`, `PostReader` (thread posts and
  `find_visible_post`), the home page, the forum write path's lookups and the
  attachment upload and delete lookups. The public HTTP cache serves only
  anonymous requests, whose readers now return public rows only.
  `t/199-effective-visibility.t` pins the rules and
  `t/integration/postgres-effective-visibility.t` the pages, against
  PostgreSQL, for anonymous, member, author, granted and suspended readers.
- **Stage 2, search:** `Search::PermissionEngine` applies the same rule:
  the document's own visibility from index time, its category and space
  joined live (`SearchDocument` gained the `category` and `space`
  relations), for search and autocomplete, with the resolved viewer passed
  by the controller. A category that turns private leaves search at once.
- **Stage 2, syndication and profiles:** the sitemap and Atom feed take
  the latest-threads list with an anonymous viewer, so only threads in
  public categories of public spaces; `/u/:username` lists only public
  threads and replies in public, live categories of public spaces, for every
  reader; a thread page's robots and OpenGraph metadata judge the effective
  visibility of the thread, its category and its space.
- **Stage 3, notifications and mentions:** the notification dispatcher's
  permission hook is wired (`Notification::RecipientPolicy`): a recipient is
  notified about a post or thread only if they can read it, a public source
  costing one query; missing, removed or hidden sources notify nobody. A
  mention of someone who cannot read the source is not recorded
  (`source_not_readable`).
- **Stage 3, attachment downloads:** a file linked to a post or thread is
  served to readers of that post or thread (`RecipientPolicy::readable_by`,
  the same check as notifications, reusing the request's viewer) and to its
  uploader. Before, the linked post's own visibility decided, and a public
  post in a private category served its files to anonymous visitors.
- **Review of stage 1** (adversarial, three lenses and a skeptic per
  finding): the cursor page of a thread lost the post filter for signed-in
  readers; restoring a thread skipped the viewer; category pages judged
  their threads without the category's context; suspended authors still read
  their own private threads (authorship now requires membership); a binding
  scoped to anything but global, a space or a category granted its whole
  space. Each is fixed with a test that fails on the old code.
- **Stage 3, lists and realtime:** `GPForum::Service::Forum::Readability`
  (formerly inside `Notification::RecipientPolicy`, which now extends it)
  answers for one source (`readable_by`), for many readers of one source
  (`readers_of`, one placement query) and for lists (`sources_condition`).
  The notification inbox and its unread count, the realtime badge, mentions,
  bookmarks and the personal feed filter in SQL before `LIMIT` with a
  subquery correlated on the row's id -- a primary-key lookup per row; the
  uncorrelated form became a hashed subplan that read every thread. Realtime
  thread channels open to readers of the thread (space included, members
  vs private) and every broadcast on one re-asks: a subscriber who cannot
  read the thread now is sent nothing but stays subscribed, so a restored
  thread or a returned grant resumes; an event about one post goes only to
  readers of that post. `resource_acl` is no longer read. The SQL rule
  gained the Perl rule's private-thread owner for posts.
- **Review of stage 3** (adversarial, as for stage 1) confirmed six defects,
  each fixed with a test that fails on the old code: the liveness check read
  a restricted hash with the key `hidden` and died, taking down
  notifications, downloads and realtime for any hidden thread; realtime
  announced a private reply's id and author to every subscriber of a public
  thread; hiding or deleting a thread unsubscribed every open page for good;
  "mark all read" counted notifications the inbox hides; the unread count
  had no bound and ran a lookup per unread row on every delivery (now capped
  at "more than 99", with the type test ahead of each lookup); and the
  thread page's attachment list resolved the reader again per file.
- **Write path:** a new thread without a visibility inherits its category's
  effective visibility (space and category), a reply its thread's (space,
  category, thread); a broader one is refused by `ThreadComposer` or
  `PostComposer` (`Visibility::broader`). The new-thread form defaults to
  "Same as the category" and the reply form no longer sends the thread's
  own visibility, which made every reply to a public thread in a
  members-only category public.
- **Public HTTP cache:** implemented as event-driven invalidation, not the
  render-time fingerprint above: the cache already serves only anonymous
  requests, whose readers return only effectively public rows, so the one
  risk left was a page cached while its content was public. The outbox's
  cache handler now purges a thread's public page on every thread and post
  event (`forum:thread:<id>`, and its category's page), and the whole public
  HTML cache on moderation (hide, restore, lock, unlock, reversal) and on
  category create or update, whose events do not name every page they
  change. `post.hidden`, `post.restored`, `thread.locked`,
  `thread.unlocked` and `moderation_action.reversed` were not handled at
  all, and the `forum:thread:<id>` tag was never invalidated: a hidden
  thread or a category turned private stayed on cached public pages until
  the entry expired (60 s by default). The cross-process bus carries the
  purge to every web worker.

## Alternatives Rejected

- Filtering in Perl after `LIMIT`: short pages, N+1 permission queries, and
  cursor drift; rejected in favor of SQL joins.
- Letting the author override lift space and category restrictions: exposes
  other people's replies after access is revoked.
- Materializing `effective_permissions`: needs a rebuildable projection and
  invalidation workflow that does not exist yet; live joins on small tables
  are cheaper and always current.
- Collapsing `members`/`private` into "not public": loses the product
  distinction the schema already models.
- Caching members pages with `Cache-Control: private`: rejected by ADR 0019;
  the public cache stays anonymous-only.

## Alignment

- `prompt/52.txt` sections 5, 12, 13, 14, 16, 17, 18, 20, 22
- `prompt/53.txt` section 15
- `docs/adr/0007-websocket-authorization-policy.md`
- `docs/adr/0019-public-cache-access.md`
- `docs/adr/0022-attachment-download-access.md`
- `docs/adr/0030-discovery-access.md`
- `docs/adr/0041-forum-access.md`
- `docs/adr/0042-attachment-access.md`
- `t/199-effective-visibility.t`, `t/integration/postgres-effective-visibility.t`
- `t/118-attachment-download-access.t` (attachment surface only; a dedicated
  effective-visibility suite covering the other rows of the enforcement
  table is not written yet)
- `t/integration/postgres.t`
