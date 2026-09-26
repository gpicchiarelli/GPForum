# Dead-letter review

Exhausted outbox messages stay in `outbox_messages` as `cancelled` and are
copied to append-only `dead_letters`. `(source_table, source_id)` is unique,
so a recorder retry reuses that review row. They are a review surface. They
are never replayed automatically and are not deleted by the dispatcher; an
operator replays one, once its cause is fixed (ADR 0056).

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
`Admin::ConsoleReader::list_dead_letters`, newest first, with their failure
type and the state of each one's replay if it has one. From the shell:

```sh
script/dead-letter-replay --list --limit 100
```

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
2. When the cause was outside the message -- a handler bug since fixed, a
   dependency that was down -- **replay** it, from the dead letter's Replay
   button on `/admin/jobs` or from the shell:

   ```sh
   script/dead-letter-replay --id DEAD_LETTER_ID
   ```

   A replay enqueues a **new** outbox message for the same event, job and
   payload, with a fresh retry budget and the idempotency key
   `dead-letter-replay:DEAD_LETTER_ID`. The cancelled message and the dead
   letter are left exactly as they were: they are the record of what failed.
   The audit log records each replay as `outbox.dead_letter_replayed`, with
   the administrator, or no actor and `via: cli` from the shell -- and that
   record is what makes a dead letter replay **once**: retention purges the
   replay message after seven days like any other, but the audit log is
   never purged, so the dead letter reads `replayed` and refuses a second
   replay for as long as it is kept. If the replay fails in turn, it has its
   own dead letter.

   The replay is built from the dead letter's own copy of the envelope, so
   it works for the thirty days a dead letter is kept, after retention has
   purged the cancelled message (seven days).

   What a replay repeats depends on the handler. The ones keyed in
   `Outbox::HandlerIdempotency` -- search, notifications, feeds, reputation,
   cache, media and attachment scanning -- skip what they already did for
   the event. **Identity mail is not keyed** (it is at-least-once; see
   `docs/OUTBOX_LIFECYCLE.md`): replaying an `identity.mail.requested` dead
   letter sends the mail again, with the token it carried, even if an earlier
   attempt reached the mail server before failing.
3. When the payload itself is wrong, patch the data and emit a new outbox
   message from a canonical write. Never `UPDATE dead_letters` into a replay,
   and never flip `outbox_messages.status` from `cancelled` back to
   `pending`: both would erase the evidence of the failure.
4. Purge only aged review rows through the scheduled retention job. Default
   cadence is hourly:

```sh
script/gpforum-carton exec bin/gpforum-scheduled-jobs --once --limit 100
```

`purge_dead_letters` deletes `dead_letters` older than the retention cutoff.
It does not revive cancelled outbox rows.

## Staging check

Automate the rehearsal (in-memory dispatcher stack; EvidenceMeta JSON):

```sh
script/dead-letter-check --simulate --human
script/dead-letter-check --dry-run --json
# Archive: script/dead-letter-check --json > /tmp/dead-letter-check.json
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
