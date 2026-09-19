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
ma non dimostrano lock scheduling, timeout, isolamento, errore dopo commit o
crash worker.

## Registro failure mode

| ID | Scenario | Stato attuale | Rischio | Severità | Test o patch richiesto |
| --- | --- | --- | --- | --- | --- |
| FM-001 | Database down su route write | readiness/realtime coperti in parte | errore HTTP non uniforme o leakage | high | test web per create_reply, report, moderation, privacy con DB indisponibile |
| FM-002 | Database timeout durante transazione | non coperto end-to-end | transazione parziale o risposta 500 opaca | high | fake DBI timeout su insert event/outbox/audit e rollback verificato |
| FM-003 | Errore prima del commit | forum outbox failure coperto | side effect parziali in altre aree | high | estendere rollback test a report, moderation action, privacy approval |
| FM-004 | Errore dopo commit ma prima risposta HTTP | non coperto | retry client può duplicare se manca idempotenza | high | retry identico con `command_id` per write principali |
| FM-005 | Worker crash dopo dispatch prima di mark done | outbox stale lock riclamabile | side effect duplicato se handler non idempotente | medium | test crash/reclaim e catalogo dedupe handler |
| FM-006 | Minion non disponibile | configurazione incompleta fallisce | confusione deploy o worker assente | medium | test `GPFORUM_MINION_ENABLED=1` con backend assente e fallback direct outbox documentato |
| FM-007 | Outbox retry esaurito | coperto da dispatcher/dead-letter | dead-letter non drenata in staging | medium | staging test con failure permanente e runbook dead-letter |
| FM-008 | Job duplicato privacy approval | mitigato da migration `024` e lock request | doppia erasure job | low residuo | test PostgreSQL concorrente con due connessioni reali |
| FM-009 | Command log race | unique + catch replay/`in_progress` in `CommandIdempotency` | evidenza PG concorrente residua | low residuo | test PostgreSQL con due connessioni reali |
| FM-010 | Audit hash-chain branching | `pg_advisory_xact_lock` prima del lookup; errori di chain non inghiottiti | evidenza PG concorrente residua | low residuo | test PostgreSQL con due append concorrenti |

## Test già presenti utili

| Area | Evidenza |
| --- | --- |
| outbox retry/dead-letter | `t/13-outbox-dispatcher.t`, `t/84-outbox-concurrent-dispatcher.t` |
| worker wiring | `t/16-workers-phase.t`, `t/83-outbox-worker-wiring.t` |
| forum rollback | `t/86-engineering-correctness.t` |
| privacy erasure idempotente | `t/29-privacy-rights.t` |
| realtime DB unavailable | `t/81-realtime-operational.t` |
| readiness payload | `t/23-operations-hardening.t`, `t/77-web-technical-payloads.t` |

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

1. Evidenza PostgreSQL reale per `command_log`, report, bookmark, subscription
   e audit chain (già chiusi in codice/fake).
2. Worker crash: dispatch riuscito, crash prima di mark done, reclaim dopo
   `locked_until`, handler idempotente.
3. Errore dopo commit HTTP: simulare risposta persa e retry client sulle write
   principali.
4. Privacy deletion/hold/export: unique o command replay come gli altri store.
