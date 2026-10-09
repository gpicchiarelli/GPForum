# ADR 0121: A Page Is Rendered Once per Input, and Warmed Before the Fork

## Status

Accepted (2026-10-08). Builds on ADR 0111 (scaling directives) and the
prepared statements of `docs/PERFORMANCE.md`; the owner's directive was to
optimise everything that renders, to the limit of the engineering, with the
pages left byte for byte as they were.

## Context

NYTProf on the signed-in thread page (25 posts of a 120-post thread, 79 KB,
8 statements) said rendering was 62% of the request and the database 10%.
Inside the rendering, most of the time was spent producing values that do
not change between requests, or between the forms of one page:

- `csrf_field` on each of the page's 33 forms masked the session's token
  anew against BREACH, and each mask opened `/dev/urandom` (Mojolicious
  reads it there when `Crypt::PRNG` is not installed): 33 opens a request.
- Each of 25 timestamps built two `DateTime` objects in the viewer's zone,
  found the zone's offset for each, and formatted three strings.
- 365 `t()` lookups each went through seven subroutines (helper, helper,
  locale helper, service, resolver) to read one hash entry.
- 64 route paths each walked the route's chain of parents and every token
  of every pattern.
- The response was gzipped at zlib's level 6 through `IO::Compress::Gzip`:
  1.6 ms, of which 0.3 ms were the module's layers.
- Every worker compiled the page's templates and prepared its statements on
  its first request: 95 ms for the home page where the second took 16.

## Decision

1. **A value computed from the same input is computed once.** The CSRF
   token is masked once per response and the field written once (BREACH
   compares one response with the next, not one form with the next; Django
   masks once per request the same way). Formatted dates are kept by
   locale, zone and value; rendered post bodies by source; translated plain
   messages are read straight from the i18n service's resolved table; a
   route's path is the join of parts read once from its patterns; an asset
   URL is a string kept by base path and name. Every memo is bounded and
   cleared when full rather than kept in order.
2. **The same bytes.** Each change was held to the page it replaced: the
   HTML of fourteen pages, anonymous and signed in, with the per-request
   values masked, is identical before and after, and so are the headers.
3. **gzip at level 3 through `Compress::Raw::Zlib`.** On the 79 KB page level
   3 takes 0.67 ms for 9.0 KB where level 6 took 1.28 ms for 8.1 KB; one
   deflate stream serves the process, reset between responses. The
   renderer's own compression is off so a page is never encoded twice, and
   the hook writes the headers `Mojolicious::Renderer::respond` wrote.
4. **The manager warms the pages before it forks.** Under a pre-forking
   server (Hypnotoad, `prefork`), `before_server_start` renders the home
   page, the category index, the login and registration forms, and the
   newest thread with its category, through an in-process client, so every
   worker inherits the compiled templates, the prepared statements and the
   filled memos. The realtime listener is not started for those requests
   and the manager's database connection is closed afterwards, so no worker
   inherits a connection. `GPFORUM_WARMUP_ENABLED` turns it off. A single
   process (daemon, morbo, the test client) is not warmed.
5. **The lookups by a key a signed-in page runs are prepared too**: the
   viewer's read state, bookmark and subscription for the thread, and the
   session the cookie names, through `GPForum::Infrastructure::PreparedQuery`,
   which now keeps a statement with no page size as well as one with one.

## Consequences

In process on the development laptop (bench database, `hot-thread` seed):
the signed-in thread page went from 24.7 to 13.6 ms, the category page
from 15.1 to 11.5, the home page from 17.5 to 11.7, and the anonymous cached
thread page from 2.7 to 1.6; NYTProf's profiled time per request fell from
65 to 33 ms. Under `prefork` with two workers the first request to a worker
took 21 ms for the home page and 17 ms for the thread, against 95 and 35
unwarmed.

What it costs: a few megabytes per worker of memos at their bounds (8,192
formatted dates, 2,048 rendered bodies), 900 more bytes on the wire for the
thread page, and a start that takes 200 ms longer while the manager warms.
A deploy whose database is not up when the server starts warms the pages
that need none and logs the rest.

What it does not do: an escape is still a subroutine call per expression
(1,269 a page) and a template's own code is a quarter of the request; an
XS escaper would be a new dependency and writes braces and backticks as
entities, so the page would change.

Amended 2026-10-09: the attachments statement, with a list of post ids, was
the one statement of the page still built per request; `PreparedQuery`
binds a list once per element, kept by page size, and it is prepared too.
`PreparedQuery` also sends no statement for a value bound to a uuid column
that PostgreSQL would not read as one, so `/t/anything` is a 404 before
any statement rather than a 500 and a line in the error log.
