# ADR 0024: Forum View-Model Form, Page, and Row Boundaries

## Status

Accepted.

## Context

`ViewModel::Forum::Presenter` mixed row mapping, thread-page assembly,
new-thread form descriptors, search payloads, and engagement summaries.
`new_thread_form` and `thread_page` exceeded the complexity ceiling. Post body
and engagement logging used postfix control. ADR 0003 already asked presenters
to stay serialization-only; the forum presenter had become the catch-all.

## Decision

Split the forum view model behind the existing facade:

- `GPForum::ViewModel::Forum::Rows` owns category, thread, post, search,
  autocomplete, and report hashes;
- `GPForum::ViewModel::Forum::Form` owns new-thread field descriptors and
  defaults;
- `GPForum::ViewModel::Forum::Page` owns page assembly, summaries, and
  mutation responses.

`GPForum::ViewModel::Forum::Presenter` remains the helper used by bootstrap
and controllers.

## Consequences

Form defaults and thread-page attachments are unit-testable without HTTP.
Public JSON field names stay unchanged. Controllers keep calling
`gp_forum_view_model`.

## Alternatives Rejected

- Put form descriptors in controllers: rejected by ADR 0003.
- Merge form state into `Forum::Write` controllers: rejected because HTTP
  already delegates payload shape to the view model.

## Alignment

- `docs/adr/0003-ssr-view-models.md`
- `docs/VIEW_MODELS.md`
- `docs/architecture/presentation.md`
- `t/74-view-model-presenters.t`
- `t/120-forum-view-models.t`
