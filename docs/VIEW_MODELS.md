# GPForum SSR View Models

GPForum uses SSR-first templates. Controllers should stay focused on HTTP:
authorization, CSRF, rate limits, service calls, status codes, redirects, and
content negotiation. They should not hand-build large rendering hashes.

Use `GPForum::ViewModel::*` presenters for page and domain payload shaping.

## Rules

- Return plain hashes and arrays only. Do not pass DBIx::Class result objects to
  templates.
- Preserve existing public JSON field names unless the API change is deliberate.
- Keep HTML out of view models. Safe rendered post bodies may pass through as
  already-sanitized content from the forum read model.
- Put accessibility metadata in predictable `ui` structures, for example
  `heading_id`, `described_by`, `permalink`, or `reversible`.
- Build HTML ids through `stable_id` when values originate from rows, params, or
  operational identifiers. This keeps SSR landmarks deterministic without
  trusting raw database strings as DOM ids.
- Keep localization at the presentation boundary. Use existing i18n or
  notification rendering services; do not translate user content.
- Keep pagination metadata explicit: `next_cursor`, `has_more`, `more_limit`,
  and stable link labels belong in the payload.
- Treat moderation and privacy visibility as already enforced by readers and
  stores; view models may shape state labels but must not bypass authorization.

## Adding A Presenter

Create a focused module under the product surface, such as:

```perl
package GPForum::ViewModel::Forum::Presenter;

use Mojo::Base 'GPForum::ViewModel::Base';

sub thread {
    my ( $self, $row ) = @_;

    return {
        thread_id => $self->column( $row, 'thread_id' ),
        title     => $self->column( $row, 'title' ),
        ui        => {
            heading_id => 'thread-' . $self->column( $row, 'thread_id' ),
        },
    };
}
```

Register long-lived presenters through `GPForum::Bootstrap::UI` as helpers, then
call them from controllers:

```perl
my $payload = $self->gp_forum_view_model->category_page(
    category     => $category,
    threads_page => $threads,
);
```

Operational surfaces should follow the same rule. For example, Admin presenters
shape user rows, outbox messages, dead-letter rows, and operations status before
templates render them; controllers still preserve the raw compatibility payload
where JSON clients already expect it.
Identity presenters own form field descriptors and error-summary wiring, while
Moderation presenters own action/control ids for reversible workflows.

## Testing

Presenter tests should cover:

- serialization compatibility for existing fields;
- absence of blessed row objects in returned payloads;
- locale-aware rendering where the presenter prepares user-visible shell text,
  such as notification inbox and mention presentation;
- accessibility metadata such as heading ids and described-by targets;
- degraded or anonymous states when a page can render without a logged-in user.
