# Presentation Architecture

GPForum keeps SSR presentation in three layers:

- controllers collect input, enforce auth/CSRF/rate-limit decisions, call
  services, and choose HTTP status or redirects;
- `GPForum::ViewModel::*::Presenter` modules shape plain Perl hashes for SSR
  templates and JSON-compatible responses;
- `templates/components/*.html.ep` render reusable semantic HTML primitives.

View models accept DBIx::Class-like rows and plain hashes through
`GPForum::ViewModel::Base`. Returned payloads must not contain blessed result
objects. Stable UI metadata such as heading ids, field ids, anchors, and
reversibility flags belongs in `ui` hashes.

Current presenter boundaries:

- Forum: categories, threads, posts, search, autocomplete, reporting, reading,
  engagement, and new-thread form state.
- Community: bookmarks and feed, while notification methods delegate to the
  dedicated Notifications presenter for compatibility.
- Notifications: inbox rows, mentions, localized notification presentation, and
  notification-specific heading metadata.
- Admin, Moderation, Privacy, Identity, Attachments, and Discovery: SSR/JSON
  payloads for their product surfaces.

Services must not render HTML. The only exception is already-sanitized post body
HTML produced by the forum read model and passed through by the presenter.
