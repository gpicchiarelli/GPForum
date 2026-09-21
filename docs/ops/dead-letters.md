# Dead-letter review

Exhausted outbox messages stay in `outbox_messages` as `cancelled` and are
copied to append-only `dead_letters`. `(source_table, source_id)` is unique,
so a recorder retry reuses that review row. They are a review surface. They
are not replayed automatically and are not deleted by the dispatcher.

## How a message reaches dead-letter

- Transient, serialization, authorization, and transport failures retry until
  `max_attempts` (default 5). The last failure marks the row `cancelled` and
  inserts one `dead_letters` row.
- A classified `permanent` failure cancels and dead-letters on that attempt.
  It does not sit in `failed` waiting for later retries.
- A later dispatcher pass does not claim `cancelled` or `done` rows. One
  outbox id produces at most one live-queue drain and one review row.

## Inspect

Admin `/admin/jobs` lists recent dead letters through
`Admin::ConsoleReader::list_dead_letters`. The bounded list is ordered by
`last_failed_at`.

On the database:

```sql
SELECT dead_letter_id, source_id, failure_type, retry_count,
       error_class, error_message, last_failed_at
  FROM dead_letters
 ORDER BY last_failed_at DESC
 LIMIT 100;

SELECT outbox_id, status, failure_type, attempt_count, last_error
  FROM outbox_messages
 WHERE status = 'cancelled'
 ORDER BY next_attempt_at DESC
 LIMIT 100;
```

Read `failure_type` before acting:

| Type | Typical meaning |
| --- | --- |
| `transient` | timeout, lock, or temporary handler error |
| `serialization` | payload/shape that will not decode |
| `authorization` | permission or forbidden failure |
| `transport` | notify/Pg/transport failure |
| `permanent` | handler declared the payload cannot succeed |

## Decide

1. Keep the dead-letter row as terminal evidence when the payload is invalid
   or the side effect is no longer wanted.
2. Patch data or code, then emit a **new** outbox message from a canonical
   write. Do not `UPDATE dead_letters` into a replay, and do not flip
   `outbox_messages.status` from `cancelled` back to `pending`.
3. Purge only aged review rows through the scheduled retention job. Default
   cadence is hourly:

```sh
script/gpforum-carton exec bin/gpforum-scheduled-jobs --once --limit 100
```

`purge_dead_letters` deletes `dead_letters` older than the retention cutoff.
It does not revive cancelled outbox rows.

## Staging check

Automate the rehearsal (in-memory dispatcher stack; EvidenceMeta JSON):

```sh
script/gpforum-dead-letter-check --simulate --human
script/gpforum-dead-letter-check --dry-run --json
# Archive: script/gpforum-dead-letter-check --json > /tmp/dead-letter-check.json
```

Manual confirmation on staging still required:

1. Force a handler failure classified `permanent` (or exhaust retries).
2. Confirm `/admin/jobs` shows one dead-letter row and the outbox row is
   `cancelled`.
3. Run `bin/gpforum-outbox-dispatch --once` again and confirm selected=0 for
   that id.
4. Confirm scheduled-jobs does not delete a fresh dead-letter before the
   retention window.

`--simulate` covers steps 1–4 against production `Dispatcher` code with an
in-memory outbox. It does **not** replace the live `/admin/jobs` walk.
