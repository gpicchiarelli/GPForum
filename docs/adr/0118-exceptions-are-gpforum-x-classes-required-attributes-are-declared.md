# ADR 0118: Exceptions Are `GPForum::X` Classes; Required Attributes Are Declared

## Status

Accepted. Gives ADR 0052's "structured exceptions; explicit error classes"
its classes. Builds on ADR 0117 (native `try`/`catch`).

## Context

ADR 0052 says errors MUST be typed where possible and SHOULD avoid
string-only exception handling. The code had no exception class. About 364
`croak` sites raised strings, and every consumer classified the string:

1. Stores matched constraint names with `index($error, $X_CONSTRAINT)` (75
   checks in 29 files) or asked `UniqueConflict->is_conflict`, a regex for
   SQLSTATE 23505 over the whole message. A bare `index` mistakes an "index
   row too large" error for a conflict on that index, and a member's text in
   the parameter values DBI appends can name any constraint.
2. Workflows caught a store's error, logged it and returned
   `{ status => 'failed' }`; refusals came back as strings mapped to statuses
   (`PostingWorkflow`'s `%STORE_REFUSAL_STATUS`).
3. Controllers caught reader errors and answered 500; `Web::Guard` maps the
   status strings `not_found`, `forbidden`, `conflict`, `invalid`, `failed` to
   404, 403, 409, 400 and 500/503.
4. The command line chose exit 2 over exit 1 with `/^Usage:/`, and `trimmed`
   stripped croak's " at FILE line N.".
5. The outbox's `FailureType` matched class names and messages by regex
   (serialization, authorization, transport, permanent) unless the exception
   declared a `failure_type`, which one test double did.

Separately, `has NAME => undef;` appeared 330 times in 157 files. It says
nothing about whether the class can work without the attribute: 126 are
dereferenced with no guard, so a store built without its schema fails only
when a method first reads it, far from the line that forgot to pass it.

## Decision

- **`GPForum::X` is the base exception.** A Mojo::Base object with a
  required `message`, an optional `cause` (the error it wraps), a
  `failure_type` (`transient` by default) and the `location` it was thrown
  from. It stringifies to its message and nothing else, and is true in
  boolean context whatever the message says, so every `like($error, qr/.../)`,
  `index($error, ...)`, `trimmed` and JSON encoding (`TO_JSON`) that read
  croak's strings keeps working. `location` stays out of the string, so a
  message does not change with a line number. `throw` builds and croaks it,
  recording the caller; `rethrow` croaks it again; `caught($class, $error)`
  is the error when it is one of the class, undef otherwise.
- **Six subclasses, derived from how errors are classified today:**

  | Class | Meaning | `failure_type` | Answer |
  | --- | --- | --- | --- |
  | `X::Argument` | A caller broke a method's contract, including a missing required attribute | permanent | 500 |
  | `X::Config` | The configuration is invalid | permanent | exit 1 |
  | `X::Usage` | A command-line tool was called the wrong way; the message starts with `Usage:` | permanent | exit 2 |
  | `X::Conflict` | A PostgreSQL unique violation | transient | the store recovers or rethrows |
  | `X::Unavailable` | A dependency did not answer: clamd, the shared cache, Minion, mail, pg_dump | transport | 503, exit 1 |
  | `X::Check` | A drill or an evidence verification found what it checks to be wrong | permanent | exit 1 with failing evidence |

  `FailureType` already reads a declared `failure_type` before its regexes,
  so an X class is classified by what it declares; the regexes stay for
  exceptions GPForum does not raise.
- **Only `UniqueConflict` makes an `X::Conflict`.** `attempt` returns a
  unique violation its code raised as an `X::Conflict` that stringifies to
  the original DBI text and carries the schema; any other error comes back
  unchanged. `throw` raises one with the text the test doubles raised
  before. Only the server's own sentence -- the first line, without DBI's
  appended statement and parameters -- decides that an error is a conflict.
  `$conflict->on($constraint)` answers whether it is a conflict on that
  constraint, including the index a partition of a partitioned table
  attached to it, read from the catalog when asked (ADR 0113, ADR 0116),
  because PostgreSQL names the partition's index in the message. The rules
  live in `X::Conflict`; `UniqueConflict->is_conflict` and `is_conflict_on`
  delegate to them, so there is one copy.
- **Refusals are not exceptions.** There is no `NotFound`, `Forbidden` or
  `Invalid`. A refusal is a result value, because `CommandIdempotency`
  records a command's result and replays it, and an exception cannot be
  replayed. `Web::Guard`'s status mapping stays.
- **A class declares the attributes it cannot work without.** A class that
  extends `GPForum::Base` writes `__PACKAGE__->requires(qw(schema))`.
  `requires` declares accessors with no default and records them per class;
  `new` takes a list of pairs or a hash reference as Mojo::Base does, walks
  the method resolution order and throws `X::Argument` (`"Store requires
  schema"`, located at the caller of `new`) when any required attribute is
  missing or undef. `required_attributes` lists them, inherited ones first.
  A defined false value counts as given, and lazy defaults of the other
  attributes are still built on first read. An attribute a class can work
  without stays `has NAME => undef;` with an `# optional:` comment saying
  why.
- **Layering.** `X` and `Base` belong to the foundation layer (ADR 0107), so
  every layer may raise and catch them. `X` uses no other GPForum module
  (it loads `X::Argument` only to refuse an exception without a message);
  `Base` uses `X::Argument`.

## Consequences

- Phase 2 converts slice by slice: `index($error, ...)` and `is_conflict`
  become `$error->on(...)`, deleting the three conflict predicates each store
  keeps; `Command::Usage->is_usage` checks the class before its regex, and
  the regex goes once the last option parser throws `X::Usage`; `Config.pm`
  and the antivirus, Minion and notification code raise `X::Config` and
  `X::Unavailable`; the drills raise `X::Check`; evals become `try`/`catch`
  (ADR 0117). Each step ships on its own, and because an exception
  stringifies to its message, a consumer that still reads strings keeps
  working until it is converted.
- Classes move to `GPForum::Base` one at a time, with the unit tier run each
  time: an eager check breaks the tests that build partial objects, and those
  fixtures are fixed rather than the check weakened.
- Later gates: no `index($error` constraint matching, no `eval {` and no
  `$EVAL_ERROR` in `lib/`, and no `has NAME => undef;` without
  `# optional`, once the slices are converted.
- `X::Conflict->on` reads the catalog on each call against a partitioned
  table's constraint. Partitions are attached while the application runs, so
  the family is not cached.

## Alignment

- ADR 0052 (error handling philosophy), ADR 0107 (layers), ADR 0113 and
  ADR 0116 (partitions), ADR 0117 (`try`/`catch`).
- `lib/GPForum/X.pm`, `lib/GPForum/X/Argument.pm`, `lib/GPForum/X/Config.pm`,
  `lib/GPForum/X/Usage.pm`, `lib/GPForum/X/Conflict.pm`,
  `lib/GPForum/X/Unavailable.pm`, `lib/GPForum/X/Check.pm`,
  `lib/GPForum/Base.pm`, `lib/GPForum/Infrastructure/UniqueConflict.pm`,
  `lib/GPForum/Service/Outbox/FailureType.pm`,
  `lib/GPForum/Application/LayerMap.pm`.
- `t/322-exceptions.t`, `t/323-base-requires.t`, `t/192-layering.t`.
