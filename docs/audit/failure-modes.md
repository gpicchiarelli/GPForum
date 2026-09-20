# Audit failure mode

Data: 2026-06-02.

Scopo: rendere riproducibili i guasti che possono corrompere stato, perdere
eventi, duplicare job o degradare il servizio. Questo documento è diagnostico:
non aggiunge feature e non sostituisce i test PostgreSQL/staging richiesti prima
del go-live.

## Stato sintetico

GPForum ha già una buona base:

- canonical write con `txn_do` in forum, moderazione, privacy e outbox;
- outbox claim con `FOR UPDATE SKIP LOCKED`;
- retry/backoff/dead-letter per outbox;
- health readiness con check database;
- test su rollback forum quando outbox/event append fallisce;
- test su realtime degraded quando database o LISTEN/NOTIFY non sono
  disponibili;
- CI con migrazioni, query plan evidence, benchmark smoke e coverage.

Il gap principale è la prova sistematica dei failure mode distruttivi o
concorrenti su PostgreSQL reale. I test fake/unitari validano contratti e shape,
ma non dimostrano lock scheduling, isolamento concorrente o crash worker.
Timeout in transazione e retry HTTP dopo una risposta persa sono coperti dai
test fake.

## Registro failure mode

| ID | Scenario | Stato attuale | Rischio | Severità | Test o patch richiesto |
| --- | --- | --- | --- | --- | --- |
| FM-001 | Database down su route write | 503 uniforme su create_reply, report, hide, export, password-reset, verification-resend e email-change | errore HTTP non uniforme o leakage | high | coperto da `t/152-write-unavailable.t` |
| FM-002 | Database timeout durante transazione | timeout EventLog/outbox/audit con rollback | transazione parziale o risposta 500 opaca | high | coperto da `t/86-engineering-correctness.t` |
| FM-003 | Errore prima del commit | report, hide, approval rollback su outbox fail | side effect parziali in altre aree | high | coperto da `t/86-engineering-correctness.t` |
| FM-004 | Errore dopo commit ma prima risposta HTTP | retry HTTP con stesso `command_id` | retry client può duplicare se manca idempotenza | high | coperto da `t/153-lost-response-retry.t` |
| FM-005 | Worker crash dopo dispatch prima di mark done | stale lock riclamabile; handler skip su replay | side effect duplicato se handler non idempotente | medium | coperto da `t/150-outbox-handler-idempotency.t` e reclaim in `t/84-outbox-concurrent-dispatcher.t` |
| FM-006 | Minion non disponibile | fail-closed se abilitato; outbox-dispatch salta Minion | confusione deploy o worker assente | medium | coperto da `t/83-outbox-worker-wiring.t` |
| FM-007 | Outbox retry esaurito | cancelled + dead-letter; permanent fail-fast; no re-claim | dead-letter non drenata in staging | medium | coperto da `t/13-outbox-dispatcher.t` e `docs/ops/dead-letters.md` |
| FM-008 | Job duplicato privacy approval | mitigato da migration `024` e lock request; evidenza PG in `t/integration/postgres-concurrency.t` | doppia erasure job | closed | due approval concorrenti → un solo erasure job |
| FM-009 | Command log race | unique + catch replay/`in_progress`; evidenza PG in `t/integration/postgres-concurrency.t` | 500 unique violation | closed | stesso `command_id` concorrente → un winner, replay/`in_progress` |
| FM-010 | Audit hash-chain branching | `pg_advisory_xact_lock` + evidenza PG in `t/integration/postgres-concurrency.t` | chain branch | closed | due append concorrenti → catena lineare senza branch |

## Test già presenti utili

| Area | Evidenza |
| --- | --- |
| outbox retry/dead-letter | `t/13-outbox-dispatcher.t`, `t/84-outbox-concurrent-dispatcher.t`, `docs/ops/dead-letters.md` |
| worker wiring | `t/16-workers-phase.t`, `t/83-outbox-worker-wiring.t` |
| handler crash/replay | `t/150-outbox-handler-idempotency.t` |
| claim crash before dispatch | `t/84-outbox-concurrent-dispatcher.t` |
| forum rollback | `t/86-engineering-correctness.t` (thread, report, hide, approval) |
| privacy erasure idempotente | `t/29-privacy-rights.t` |
| realtime DB unavailable | `t/81-realtime-operational.t` |
| readiness payload | `t/23-operations-hardening.t`, `t/77-web-technical-payloads.t` |
| write DB unavailable | `t/152-write-unavailable.t` |
| lost HTTP response retry | `t/153-lost-response-retry.t` |
| Minion backend absent | `t/83-outbox-worker-wiring.t` |
| erasure rollback after revoke | `t/86-engineering-correctness.t` |

## Patch applicata in questo incremento

`PRIV-002` è stato mitigato:

- `migrations/024_privacy_erasure_job_idempotency.sql` aggiunge
  `idx_erasure_jobs_request_unique`;
- `ErasureJob` espone `erasure_jobs_request_key`;
- `DeletionWorkflow::approve_request` blocca la deletion request con
  `FOR UPDATE` prima di cercare o creare il job;
- `t/29-privacy-rights.t` verifica lock, replay approval e assenza di job/action
  duplicati.

## Prossimi failure test prioritari

1. Staging: lock outbox `running` scaduto e reclaim su PostgreSQL reale.
2. Evidenza PostgreSQL concorrente ancora aperta per reputation source unique
   (`event_idempotency_keys` è coperto da `postgres-concurrency.t`).
