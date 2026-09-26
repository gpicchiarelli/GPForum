# Search rebuild and lag

`search_documents` is a projection: the outbox's search handler keeps it in
step with threads and posts, and ADR 0062 accepts that it can lag. It can be
rebuilt from the canonical rows at any time (ADR 0110).

## Is search behind?

```sh
script/search-rebuild --status
```

```text
search status=current pending=0 lag_seconds=0 oldest=-
```

`pending` counts the outbox messages not yet delivered (`pending`, `running`
or `failed`); `lag_seconds` is the age of the oldest. Every message passes
through every handler for its event, search included, so this is an upper
bound on how far search is behind. A lag that keeps growing while `pending`
does not fall means the dispatcher is stopped or failing: see
[scheduled jobs](scheduled-jobs.md) and [dead letters](dead-letters.md).

## From the console

`/admin/jobs` shows the same lag and the last rebuild started from the
console, with its totals, and has two buttons:

- **Rebuild search index** starts a rebuild that runs through the outbox,
  one batch of 500 per message (`search.rebuild_requested`), until a
  `search.rebuild_completed` event records its totals. Whatever runs the
  dispatcher runs it; a failed step is retried and dead-lettered like any
  other message, and a large forum never holds the dispatcher for long.
- **Purge page cache** drops every cached public page, in every web process,
  and the anonymous category list. Pages are rendered again on their next
  visit.

Both are audited (`admin.search_rebuild_requested`, `admin.cache_purged`).

## Rebuild from the shell

```sh
script/search-rebuild                  # threads and posts
script/search-rebuild --entity post    # posts only
```

```text
rebuilt entity_type=all indexed=12 unchanged=48210 pruned=3
```

Every live thread (visible or locked) and every visible post in a live
thread is indexed again, 500 at a time, and documents whose thread or post
is gone, deleted or hidden are removed (`pruned`) -- rebuilding threads
alone removes a dead thread's posts too. Documents that did not change are
left alone (`unchanged`), so a second run reports nothing to do.

A rebuild and the live search handler never overwrite each other: each
document is written under its own lock, and whichever writer comes second
reads the newest source. The documents to remove are listed first and each
is checked again under its lock, so one restored meanwhile is indexed, not
lost.

Rebuild after:

- a change to the search configuration or to how documents are built;
- a search handler defect, once the fix is deployed;
- search events that were dead-lettered, instead of replaying each one;
- a suspicion of drift: search results that disagree with the forum.

It is safe while the forum serves. Each thread and post is indexed in its
own transaction; the rebuild holds no lock on the forum and no long-running
snapshot. Readers never see an empty index: documents are updated in place.

## Exit status

`0` on success, `2` on misuse; a database failure prints its error and
exits non-zero.
