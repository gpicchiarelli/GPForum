# Shared HTTP Access Decisions

`GPForum::Web::Access` is the shared decision helper for CSRF validity,
cookie-session user id, JSON negotiation, and non-empty text.
`GPForum::Web::RealtimeAccess` owns websocket origin matching, payload size,
subscribe-message shape, channel-type parsing, `user`-scope
connect/subscribe rate-limit hashes, and plaintext handshake texts.
`GPForum::Web::CookieSession` owns cookie-session presence, the 30-day login
lifetime, expiry, clearing, and login-value assembly.
`GPForum::Web::PublicCacheAccess` owns anonymous GET/HEAD cacheability and
ETag/Last-Modified freshness for public SSR.
`GPForum::Web::HomeAccess` owns home reader limits, the success payload, and
the custom `home_unavailable` 500 contract.
`GPForum::Web::IdentityAccess` owns identity CSRF plaintext, rate-limit
hashes, public-profile thread limits, locale/theme preference-cookie names
and options, system-failure, and bad-request rendering.
`GPForum::Web::DiscoveryAccess` owns sitemap/feed reader limits and crawler
document content-type plus body rendering.
`GPForum::Web::ForumAccess` owns forum read/write rate-limit hashes,
participation actions, report field errors, search page and autocomplete
limits, list page defaults, community target types, community write-success
statuses, search filter names, public SSR cache keys, and integer limits.
`GPForum::Web::AttachmentAccess` owns attachment upload rate-limit hashes,
filename sanitizing, content-disposition values, and Guard payloads for
invalid uploads and rate limits.
`GPForum::Web::NotificationAccess` owns inbox/mention page limits, the
`notification_http` write rate-limit hash, and `failed`/`not_found` mapping.
`GPForum::Web::ModerationAccess` owns report-queue page limits, default
open/active filters, the `moderation_http` write rate-limit hash,
permission action and resource names, write-success statuses,
permission-target hashes, and Guard payloads for invalid moderation
commands.
`GPForum::Web::PrivacyAccess` owns privacy list page limits, the
`privacy_http` write rate-limit hash, the `privacy_rights`/`manage`
permission hash, catalog `view` action, review write-success statuses,
conflict blocked-hold payloads, and Guard titles for invalid privacy
commands.
`GPForum::Web::AdminAccess` owns catalog page limits, the dashboard row
cap, the `admin_http` write rate-limit hash, the `admin_console`/`manage`
permission hash, catalog `view` action, catalog and binding write-success
statuses, Guard payloads for invalid admin commands, and the default roles
redirect.
`GPForum::Web::OperationsAccess` owns `/metrics` token presence, Bearer and
`X-GPForum-Metrics-Token` comparison, and the unauthorized JSON payload.

None of these objects store cache entries or read forum tables.
`GPForum::Web::Guard` maps shared HTTP access decisions to ErrorPayload
responses. Home unavailable rendering stays on `HomeAccess` so the home
template and error name do not change. Identity CSRF stays plaintext on
`IdentityAccess`. The realtime controller maps handshake denials to plaintext
upgrade failures and websocket error frames. `GPForum::Web::PublicHttpCache`
still stores anonymous HTML and emits 304 responses. Bootstrap identity still
validates server sessions and records telemetry. Controllers keep rate limits,
permission checks, hub registration, and telemetry.

Identity CSRF failures still render as text from
`GPForum::Web::IdentityAccess`. Access only reports whether the token is
invalid.

Coverage lives in `t/108-web-access.t`, `t/113-web-realtime-access.t`,
`t/114-web-cookie-session.t`, `t/115-web-public-cache-access.t`,
`t/122-web-home-access.t`, `t/124-web-identity-access.t`,
`t/126-web-discovery-access.t`, `t/132-web-forum-access.t`, `t/133-web-attachment-access.t`, `t/134-web-notification-access.t`, `t/135-web-moderation-access.t`, `t/136-web-privacy-access.t`, `t/137-web-admin-access.t`, and
`t/138-web-operations-access.t`.
