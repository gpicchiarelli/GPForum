# Posting Workflow Boundary

`GPForum::Service::Forum::PostingWorkflow` is the application boundary for
creating threads and replies from HTTP controllers, and for author post
edit, delete, restore, and thread title/move/delete/restore commands.

Responsibilities:

- validate category existence before thread composition;
- check the thread and the post the author writes to, with the rules of
  `GPForum::Domain::Thread` and `GPForum::Domain::Post`, before composition;
- invoke `ThreadComposer` or `PostComposer`;
- invoke `ThreadStore` or `PostStore`; a title edit, move, or post edit
  whose stored title/slug, category, or body hash already match skips the
  store restamp;
- leave unique thread `thread_id` replay inside `ThreadStore`;
- leave unique reply `post_id` replay inside `PostStore`;
- leave unique edit `body_id` and `revision_id` replay inside `PostStore`;
- leave transaction ownership inside stores;
- record mentions only after successful persistence;
- reuse unique `(source_type, source_id, mentioned_user_id)` mention rows
  on conflict without a second notification;
- degrade safely if mention recording fails;
- return a normalized result hash.

The normalized contract is:

```perl
{
    ok       => 0 | 1,
    status   => 'ok' | 'invalid' | 'not_found' | 'forbidden' | 'conflict'
              | 'failed',
    error    => $message_or_undef,
    prepared => $composer_result_or_undef,
    stored   => $store_result_or_undef,
}
```

Controllers use this contract to map workflow outcomes to redirects, SSR form
errors, or JSON responses. The workflow never performs HTTP rendering and never
duplicates persistence logic owned by stores.

## Modules

Each concern of the write path has one home:

| Module | Holds |
|---|---|
| `GPForum::Domain::Thread`, `GPForum::Domain::Post` | The refusal rules: which thread a writer can see (`shown_to_writer`), when a reply, an edit, a delete or a restore is refused and with which words, and the status each refusal means (`status_of`). The workflow asks them before the transaction; `PostStore` and `ThreadStore` ask the same rule again of the rows their locks return. |
| `GPForum::Service::Forum::PostingCommand` | The command log codec, one table keyed by command type: the request fingerprint, the response kept for each stored row, and the replay rebuilt from it. It is a contract with every command already logged: a changed fingerprint turns a retry into a conflict. |
| `GPForum::Service::Forum::Event` | The event envelopes and audit rows of every post and thread write, and their idempotency keys. |
| `GPForum::Service::Forum::PostStore`, `ThreadStore` | The transactions, the row locks, the inserts and their unique-conflict recovery, and the literal `record_event` and `record_audit` calls. |
| `GPForum::Service::Forum::PostingWorkflow` | The order: check, compose, run once per command id, store, record mentions. |

A refusal stays a result value, never an exception: the command log records
it and replays it against the command id, and an exception could not be
replayed. Where the workflow and a store disagree on a refusal there is one
rule to fix.

## Tests

- `t/72-forum-bootstrap-workflow.t`: success, invalid input, missing
  category, missing thread, locked thread, store failure, and degraded
  mention recording.
- `t/325-forum-posting-golden.t`: every command type's request fingerprint,
  result, response and replay, and the four post event envelopes, as
  canonical JSON captured before the write path was taken apart.
- `t/329-forum-thread-events-golden.t`: the thread events and audit rows,
  captured the same way.
- `t/326-forum-domain-rules.t`: the domain rules, table-driven.
- `t/327-forum-refusal-agreement.t` and
  `t/330-forum-thread-refusal-agreement.t`: for every state a post and a
  thread can be in, the store's refusal has the status the workflow answers.
- `t/328-forum-posting-command.t`: the codec.
