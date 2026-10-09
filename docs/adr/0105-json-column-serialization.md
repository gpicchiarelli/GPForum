# ADR 0105: JSON Column Serialization

## Status

Accepted.

## Context

GPForum stores event payloads, outbox payloads, audit metadata, notification
payloads, command-log payloads, moderation and suspension metadata, identity
token metadata, privacy manifests and plugin configuration in PostgreSQL
`json`/`jsonb` columns. Services build those values as Perl hash and array
references.

No Result class declared a codec for these columns. DBD::Pg cannot bind Perl
references, so every write that passed a reference failed with "Cannot bind a
reference". On a real database this broke registration, thread creation,
replies, moderation and every other evented or audited write. The failure was
invisible because unit tests use fake schemas that accept references and the
performance seeder writes JSON with raw SQL.

Reads had the mirror problem: `get_column` returns JSON text, while presenters
written against the fakes dereferenced hashes (`/notifications` failed with
"Can't use string as a HASH ref").

## Decision

- Every `json`/`jsonb` column is declared with a codec by calling
  `GPForum::Schema::JsonColumn->inflate_json_columns(__PACKAGE__)` right after
  `add_columns` in its Result class.
- The codec uses DBIx::Class `InflateColumn` (part of `DBIx::Class::Core`, no
  new dependency): references deflate to canonical JSON text (sorted keys,
  character strings) on write and inflate to Perl structures on read. Plain
  strings pass through unchanged on write.
- Column accessors and `get_inflated_column` return structures. `get_column`
  keeps returning raw JSON text; presenters that dereference a JSON column use
  `GPForum::ViewModel::Base::inflated_column`.
- Code that must compare or hash stored JSON (audit verification) decodes the
  stored value instead of hashing raw text, because PostgreSQL normalizes
  `jsonb` key order and whitespace. Timestamps are canonicalized to UTC
  ISO-8601 for the same reason (`AuditRecord::canonical_timestamp`).
- Raw SQL paths (outbox claim, seeder, query-plan evidence) keep encoding and
  decoding JSON explicitly.

## Consequences

Evented and audited writes work on PostgreSQL. `t/05-database.t` fails when a
`json`/`jsonb` column is declared without the codec, and
`t/integration/postgres.t` exercises the write paths and verifies every
persisted audit record against real SQL.

Reading a JSON column through an accessor now decodes it once per row. Hot
read paths that only need raw text can keep using `get_column`.

## Alternatives Rejected

- Encode JSON in each store before `create`: rejected because 19 columns in 15
  tables are written from many stores, and one forgotten call site reproduces
  the failure.
- Add `DBIx::Class::InflateColumn::Serializer`: rejected because core
  `InflateColumn` is enough and a new dependency needs a license review.
- Register the codec on sources after `load_namespaces`: rejected because it
  relies on sources sharing column-info hashes with their result classes.

## Alignment

- `lib/GPForum/Schema/JsonColumn.pm`
- `lib/GPForum/Schema/Result/*.pm` (15 classes with JSON columns)
- `lib/GPForum/ViewModel/Base.pm`
- `lib/GPForum/Infrastructure/AuditRecord.pm`
- `t/05-database.t`, `t/116-infrastructure-audit-record.t`
- `t/integration/postgres.t`
- `docs/adr/0020-audit-record-hashing.md`
