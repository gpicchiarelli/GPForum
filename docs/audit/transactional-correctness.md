# Audit correttezza transazionale

Data: 2026-06-02.

Scopo: congelare le nuove funzionalità e mappare ciò che può corrompere dati,
duplicare operazioni, perdere eventi o fallire sotto carico. Questo documento
non introduce feature: classifica i rischi residui e definisce patch e test
necessari per rendere il nucleo forum verificabile in produzione.

## Stato sintetico

Verdetto tecnico: quasi pronto come codebase verificabile, non pronto per
go-live production finché i rischi `critical` e `high` sotto non sono chiusi in
staging con database reale.

Punti già chiusi:

- Reply hot path: `PostStore` assegna la posizione dentro la transazione,
  blocca il thread con `FOR UPDATE` e il vincolo DB `(thread_id, position)` resta
  l'invariante finale.
- `PostPosition::next_position` non è più utilizzabile per scritture: fallisce
  esplicitamente e resta solo `read_next_position` per letture diagnostiche.
- `create_thread` e `create_reply` richiedono `command_id` al boundary HTTP e
  usano `command_log` per replay/conflict.
- `record_audit` calcola sempre `record_hash` internamente e include
  `previous_hash` nel payload canonico.

Punti ancora da chiudere prima del go-live:

- idempotenza concorrente su `command_log`;
- upsert atomico per bookmark/subscription;
- uniqueness reale dei report aperti;
- lock e `command_id` per transizioni di moderazione;
- idempotenza di deletion request e retention hold;
- hash-chain audit serializzata, non solo hash per record;
- failure test con database PostgreSQL reale e worker crash.

## Rubrica severità

| Severità | Definizione |
| --- | --- |
| critical | Può produrre effetto distruttivo, privacy/compliance errata, perdita di eventi o stato non recuperabile sotto concorrenza. |
| high | Può duplicare operazioni, audit/eventi/outbox, causare 500 su retry legittimo o lasciare stato business incoerente. |
| medium | Può degradare verificabilità, produrre audit non lineare, rumore operativo o comportamento non deterministico ma recuperabile. |
| low | Rischio operativo limitato o già mitigato da vincoli/test, da documentare o monitorare. |

## Registro rischi prioritario

### TX-001: posizione reply su thread caldo

Severità: chiuso, rischio storico `critical`.

File coinvolti:

- `lib/GPForum/Service/Forum/PostStore.pm`
- `lib/GPForum/Service/Forum/PostPosition.pm`
- `migrations/003_forum_projection.sql`

Comportamento attuale: `PostStore::_command_with_allocated_position` viene
eseguito dentro `schema->txn_do`, blocca il record `threads` con `FOR UPDATE`,
calcola la prossima posizione e inserisce `posts`. La migrazione mantiene
`posts_thread_position_key UNIQUE (thread_id, position)`.

Rischio residuo: basso. Su backend non PostgreSQL il lock dipende dal driver, ma
la produzione target è PostgreSQL.

Patch proposta: nessuna ora. Aggiungere solo evidenza PostgreSQL concorrente con
due o più connessioni reali.

Test da aggiungere: test DB-backed con 25-100 reply simultanee allo stesso
thread, verifica posizioni contigue, zero duplicati, zero errori di unique.

### ID-001: race concorrente su `command_log`

Severità: high.

File coinvolti:

- `lib/GPForum/Service/Operations/CommandIdempotency.pm`
- `migrations/004_platform_governance.sql`
- `lib/GPForum/Service/Forum/PostingWorkflow.pm`

Comportamento attuale: `CommandIdempotency::run` cerca una riga esistente prima
della transazione, poi crea la riga `command_log` dentro `txn_do`. Il vincolo
`command_log_idempotency_key_key UNIQUE (idempotency_key)` impedisce due righe,
ma due richieste concorrenti con lo stesso `command_id` possono entrambe vedere
assenza; una vince, l'altra può fallire con violazione unique invece di ricevere
replay o `in_progress`.

Rischio: retry di rete o doppio submit possono trasformarsi in errore
applicativo pur essendo la stessa operazione. La callback protetta non dovrebbe
duplicare il dominio, ma l'esperienza e l'osservabilità non sono ancora
retry-safe.

Patch proposta: spostare il controllo dentro la transazione e gestire l'insert
in modo atomico con `INSERT ... ON CONFLICT DO NOTHING RETURNING`, oppure
catturare la violazione unique, ricaricare la riga e restituire `in_progress` o
replay. Per PostgreSQL preferire un helper DBI esplicito perché DBIx::Class non
esprime bene l'upsert con ritorno.

Test da aggiungere: due processi/connessioni reali con stesso `command_id` su
`create_reply`; atteso un solo post, una sola riga `command_log`, seconda
richiesta replay o `in_progress`, mai 500.

### CM-001: bookmark non atomico

Severità: high.

File coinvolti:

- `lib/GPForum/Service/Community/BookmarkStore.pm`
- `lib/GPForum/Controller/Forum.pm`
- `migrations/007_advanced_community.sql`

Comportamento attuale: `save_bookmark` fa `find_for_user_target`, poi
`create_bookmark` o restore. Il vincolo `bookmarks_user_target_key` impedisce
righe duplicate, ma la sequenza check-then-insert non è retry-safe.

Rischio: doppio click o retry concorrente può produrre unique violation e
risposta di sistema invece dello stesso risultato.

Patch proposta: sostituire con upsert atomico su
`(user_id, target_type, target_id)` che imposti `deleted_at = NULL` e aggiorni
`note`. Aggiungere `command_id` solo se serve audit/replay HTTP completo; per
bookmark basta upsert idempotente.

Test da aggiungere: doppio `save_bookmark` concorrente; atteso una riga, stato
attivo, stesso `bookmark_id` o risposta equivalente, zero eccezioni.

### CM-002: subscription non atomica

Severità: high.

File coinvolti:

- `lib/GPForum/Service/Notification/SubscriptionStore.pm`
- `lib/GPForum/Controller/Forum.pm`
- `migrations/005_notifications_subscriptions.sql`

Comportamento attuale: `save_subscription` fa find poi insert/restore. Il
vincolo `subscriptions_unique_target` impedisce duplicati, ma non protegge la
risposta applicativa sotto concorrenza.

Rischio: retry o doppio submit su subscribe può fallire con unique violation.
Mute/unsubscribe sono più recuperabili, ma aggiornano timestamp a ogni retry e
non hanno un comando replayabile.

Patch proposta: upsert atomico per subscribe/restore; update idempotente con
`WHERE revoked_at IS NULL` o risposta stabile per mute/unsubscribe.

Test da aggiungere: subscribe simultaneo e subscribe dopo revoke simultaneo;
atteso una sola subscription attiva, nessun errore, timestamp coerente.

### MOD-001: report duplicati aperti

Severità: high.

File coinvolti:

- `lib/GPForum/Service/Moderation/ReportStore.pm`
- `lib/GPForum/Controller/Forum.pm`
- `migrations/008_moderation_review.sql`
- `migrations/016_security_abuse_hardening.sql`

Comportamento attuale: `create_report` controlla duplicato aperto dentro
transazione, poi inserisce. La migrazione `016` aggiunge un indice parziale su
report aperti/triaged, ma non è unique.

Rischio: due report concorrenti dello stesso utente sullo stesso target possono
creare due report aperti, due eventi, due outbox e due audit.

Patch proposta: nuova migrazione con unique partial index su
`(reporter_user_id, target_type, target_id) WHERE status IN ('open','triaged')`;
lo store deve catturare conflitto, ricaricare il report esistente e registrare
al massimo un audit `duplicate_blocked` controllato.

Test da aggiungere: due connessioni PostgreSQL creano lo stesso report; atteso
un solo report aperto e nessun doppio outbox `report.created`.

### MOD-002: transizioni report senza lock riga

Severità: high.

File coinvolti:

- `lib/GPForum/Service/Moderation/ReportStore.pm`
- `lib/GPForum/Controller/Moderation.pm`

Comportamento attuale: assign/release/resolve sono transazionali e hanno
controlli idempotenti sullo stato letto, ma non bloccano la riga `reports`.

Rischio: assign concorrenti o resolve concorrente possono produrre last-write
wins e audit/eventi multipli non rappresentativi dell'ordine reale.

Patch proposta: leggere il report con `FOR UPDATE`, introdurre `command_id` per
azioni HTTP di moderazione, e registrare evento/audit solo quando lo stato
cambia o quando si sta replayando lo stesso comando.

Test da aggiungere: due moderatori assegnano lo stesso report in parallelo;
atteso ordine deterministico, un solo stato finale spiegabile, audit coerente.

### MOD-003: azioni moderation su post/thread senza command-id

Severità: high.

File coinvolti:

- `lib/GPForum/Service/Moderation/ActionStore.pm`
- `lib/GPForum/Controller/Moderation.pm`

Comportamento attuale: hide/restore/lock/unlock sono dentro `txn_do` e marcano
`idempotent` se lo stato era già quello atteso. Anche quando sono idempotenti,
però, creano una nuova `moderation_actions` con evento/audit. I target non sono
letti con `FOR UPDATE`.

Rischio: retry identico o doppio click duplica azioni/audit/outbox; azioni
opposte concorrenti possono dipendere dall'ordine di commit e generare audit
difficile da verificare.

Patch proposta: aggiungere `command_id` obbligatorio al boundary di moderazione,
lock del target con `FOR UPDATE`, idempotency log per replay e nessuna nuova
azione per retry dello stesso comando completato.

Test da aggiungere: doppio `hide_post` con stesso `command_id`; atteso stesso
`moderation_action_id`, un solo evento/outbox. Test hide vs restore concorrenti
con lock e ordine deterministico.

### PRIV-001: deletion request duplicabile

Severità: high.

File coinvolti:

- `lib/GPForum/Service/Privacy/DeletionWorkflow.pm`
- `lib/GPForum/Controller/Privacy.pm`
- `migrations/004_platform_governance.sql`

Comportamento attuale: `request_deletion` genera sempre un nuovo
`deletion_request_id` e registra evento/audit. Non c'è `command_id` HTTP e non
c'è vincolo unique su richiesta pending per resource/request type.

Rischio: doppio submit crea più richieste di cancellazione/anonymize per lo
stesso utente, con queue privacy duplicata e possibili approvazioni multiple.

Patch proposta: `command_id` obbligatorio per richieste privacy; unique partial
index su pending/approved/held per `(resource_type, resource_id, request_type)`,
oppure policy esplicita che ricarica la richiesta aperta esistente.

Test da aggiungere: doppio submit e retry rete di `request_deletion`; atteso una
sola richiesta aperta e replay stabile.

### PRIV-002: approval concorrente può creare più erasure job

Severità: mitigato, rischio storico `critical`.

File coinvolti:

- `lib/GPForum/Service/Privacy/DeletionWorkflow.pm`
- `migrations/004_platform_governance.sql`
- `migrations/024_privacy_erasure_job_idempotency.sql`
- `lib/GPForum/Schema/Result/ErasureJob.pm`

Comportamento attuale: `approve_request` blocca la `deletion_requests` con
`FOR UPDATE` prima di cercare o creare il job. `erasure_jobs` ora ha vincolo
univoco su `deletion_request_id` tramite `idx_erasure_jobs_request_unique` e
schema DBIC `erasure_jobs_request_key`. Una seconda approval dello stesso
request id ricarica il job esistente e torna idempotente.

Rischio residuo: basso. Resta necessario eseguire evidenza PostgreSQL con due
connessioni reali in staging, perché i test unitari verificano lock SQL,
vincolo di migrazione e replay sequenziale, non il scheduling del kernel/DB.

Patch applicata: migration `024`, vincolo DBIC, lock esplicito su approval e
test di replay approval in `t/29-privacy-rights.t`.

Test residuo da aggiungere: due approval concorrenti dello stesso request id su
PostgreSQL reale; atteso un solo job e seconda risposta idempotente.

### PRIV-003: retention hold e stato held ripetibili senza replay

Severità: medium.

File coinvolti:

- `lib/GPForum/Service/Privacy/RetentionHoldStore.pm`
- `lib/GPForum/Service/Privacy/DeletionWorkflow.pm`
- `lib/GPForum/Controller/Privacy.pm`

Comportamento attuale: `create_hold` genera sempre un nuovo hold. `complete_job`
con hold attivo lascia il job pending con `last_error` e può registrare azioni
`held` ripetute.

Rischio: operator retry o doppio submit duplica hold e audit, rendendo meno
chiara la catena decisionale privacy.

Patch proposta: `command_id` per hold manuale; opzionale unique partial index
per active hold identico; rendere `privacy.erasure_blocked` replay-safe per
`erasure_job_id`.

Test da aggiungere: doppio hold con stesso comando e doppio run erasure bloccato;
atteso hold/action stabile e audit non duplicato.

### PRIV-004: export request privacy duplicabile

Severità: medium.

File coinvolti:

- `lib/GPForum/Service/Portability/ExportBundleBuilder.pm`
- `lib/GPForum/Controller/Privacy.pm`
- `migrations/010_import_export.sql`

Comportamento attuale: `create_request` crea sempre una nuova export request.
`complete_user_export` è idempotente per request id già completato.

Rischio: retry di export utente produce richieste duplicate e outbox duplicata.
Non corrompe dati canonici, ma crea rumore operativo e può caricare storage/job.

Patch proposta: `command_id` per export request o unique partial index per
richiesta pending dello stesso requester/subject/type/format.

Test da aggiungere: doppio request user export; atteso una sola richiesta
pending o replay esplicito.

### AUD-001: hash-chain audit non serializzata sotto concorrenza

Severità: high.

File coinvolti:

- `lib/GPForum/Infrastructure/EventRecorder.pm`
- `migrations/002_event_audit.sql`
- `migrations/004_platform_governance.sql`

Comportamento attuale: ogni audit ha `record_hash = sha256(canonical_record)`
e il record canonico include `previous_hash`. Se `previous_hash` non arriva in
input, il recorder legge l'ultimo hash disponibile. Questo rende il singolo
record tamper-evident e verificabile con `verify_audit_record`.

Rischio: due transazioni concorrenti possono leggere lo stesso ultimo hash e
creare due rami della chain. Il log resta hashato, ma non è ancora una chain
lineare totale sotto carico.

Patch proposta: introdurre stato di chain serializzato, per esempio tabella
`audit_chain_state` con una riga globale o per stream, letta con `FOR UPDATE`
dentro la stessa transazione; append audit usa il `last_hash` bloccato e poi lo
aggiorna al nuovo hash. In alternativa advisory lock PostgreSQL dedicato alla
chain audit.

Test da aggiungere: due audit append concorrenti su PostgreSQL; atteso che il
secondo `previous_hash` punti al `record_hash` del primo, senza branching.

### OUT-001: worker crash dopo dispatch e prima di mark done

Severità: medium.

File coinvolti:

- `lib/GPForum/Service/Outbox/Dispatcher.pm`
- `lib/GPForum/Service/Outbox/DomainEventTransport.pm`
- `lib/GPForum/Worker/Handler/*`

Comportamento attuale: claim PostgreSQL usa `FOR UPDATE SKIP LOCKED`, stato
`running`, `locked_by` e `locked_until`. Crash prima di `done` rende il messaggio
riclamabile dopo lock scaduto. Questo evita perdita silenziosa.

Rischio: la semantica è at-least-once. Se un handler non è idempotente per
`event_id`/`outbox_id`/idempotency key, il retry dopo crash può duplicare
side-effect.

Patch proposta: catalogare ogni worker handler con chiave idempotenza esplicita
e store dedupe; testare replay dello stesso outbox message per notification,
search, cache, attachment/media e realtime fallback.

Test da aggiungere: crash simulato tra `transport->dispatch` e `_mark_done`;
atteso nessuna perdita, eventuale doppio dispatch assorbito dagli handler.

## Matrice idempotenza scritture

| Operazione | Retry safe | Network retry safe | Double click safe | Job retry safe | Stato |
| --- | --- | --- | --- | --- | --- |
| `create_thread` | sì per comando completato | parziale, race `command_log` da chiudere | sì con stesso `command_id` | n/a | quasi chiuso |
| `create_reply` | sì per comando completato | parziale, race `command_log` da chiudere | sì con stesso `command_id` | n/a | quasi chiuso |
| `report` | parziale | no | no | n/a | richiede unique partial e replay |
| `bookmark` | parziale via unique DB | no | no | n/a | richiede upsert |
| `subscribe` | parziale via unique DB | no | no | n/a | richiede upsert |
| `moderation assign/resolve` | parziale | no | parziale | n/a | richiede lock e `command_id` |
| `moderation hide/restore/lock/unlock` | parziale | no | no, duplica azioni | n/a | richiede lock e replay |
| `privacy deletion request` | no | no | no | n/a | richiede `command_id`/unique |
| `privacy approval` | sì per retry completato | parziale, staging concorrente richiesto | sì, riusa job esistente | n/a | mitigato con lock e unique job |
| `privacy erasure completion` | parziale | n/a | n/a | parziale | blocco hold ripetuto da chiudere |
| `privacy export request` | no | no | no | n/a | richiede dedupe |
| `outbox dispatch` | at-least-once | n/a | n/a | sì se handler idempotente | handler audit richiesto |

## Controller: complessità e duplicazioni

Metodi controller oltre 30 righe rilevati con scansione locale:

| File | Metodo | Riga | Righe |
| --- | --- | ---: | ---: |
| `lib/GPForum/Controller/Admin.pm` | `user_roles` | 158 | 32 |
| `lib/GPForum/Controller/Admin.pm` | `audit` | 235 | 35 |
| `lib/GPForum/Controller/Admin.pm` | `users` | 271 | 31 |
| `lib/GPForum/Controller/Admin.pm` | `jobs` | 303 | 31 |
| `lib/GPForum/Controller/Attachments.pm` | `upload_post` | 23 | 31 |
| `lib/GPForum/Controller/Attachments.pm` | `_write_user_id` | 104 | 36 |
| `lib/GPForum/Controller/Forum.pm` | `category` | 62 | 34 |
| `lib/GPForum/Controller/Forum.pm` | `thread` | 97 | 48 |
| `lib/GPForum/Controller/Forum.pm` | `mark_thread_read` | 217 | 31 |
| `lib/GPForum/Controller/Forum.pm` | `_report_input` | 558 | 31 |
| `lib/GPForum/Controller/Forum.pm` | `search` | 726 | 81 |
| `lib/GPForum/Controller/Forum.pm` | `search_autocomplete` | 808 | 51 |
| `lib/GPForum/Controller/Identity.pm` | `register` | 44 | 49 |
| `lib/GPForum/Controller/Identity.pm` | `login` | 103 | 46 |
| `lib/GPForum/Controller/Identity.pm` | `_invalid_login` | 556 | 32 |
| `lib/GPForum/Controller/Moderation.pm` | `reports` | 35 | 32 |
| `lib/GPForum/Controller/Moderation.pm` | `actions` | 68 | 35 |
| `lib/GPForum/Controller/Moderation.pm` | `suspensions` | 104 | 36 |
| `lib/GPForum/Controller/Notifications.pm` | `inbox` | 24 | 36 |
| `lib/GPForum/Controller/Privacy.pm` | `request_deletion` | 83 | 31 |
| `lib/GPForum/Controller/Privacy.pm` | `review` | 115 | 34 |
| `lib/GPForum/Controller/Privacy.pm` | `hold_deletion` | 179 | 41 |
| `lib/GPForum/Controller/Realtime.pm` | `stream` | 21 | 39 |
| `lib/GPForum/Controller/Realtime.pm` | `_handle_message` | 61 | 41 |

Duplicazioni da ridurre dopo i fix transazionali:

- auth/write-user/permission denial ripetuti tra `Forum`, `Moderation`,
  `Privacy`, `Attachments`;
- negoziazione JSON/HTML e redirect action response ripetuti;
- validazione `reason`/`details` ripetuta nei controller;
- gestione `_system_failure`, `_bad_request`, `_not_found`, `_conflict` già
  parzialmente centralizzata in `GPForum::Web::ErrorPayload`, ma non assorbita
  da tutti i controller.

Patch proposta: estrarre piccoli helper `GPForum::Web::*` solo dopo la chiusura
dei rischi `critical/high`, partendo da `WriteBoundary` o `ActionResponse` per
`command_id`, auth write, CSRF failure, error payload e redirect. Non allargare
`Controller::Forum`.

## Failure test mancanti

| Scenario | Stato attuale | Test richiesto |
| --- | --- | --- |
| DB unavailable su readiness/realtime | coperto in parte da readiness/realtime | estendere alle write route principali con errore non leaking |
| DB timeout in transazione write | non sufficiente | fake DBI/PG con timeout su insert event/outbox e rollback verificato |
| Minion unavailable | configurazione Minion incompleta fallisce esplicitamente | test runtime con `GPFORUM_MINION_ENABLED=1` e backend assente, direct outbox ancora utilizzabile |
| Outbox retry/dead letter | coperto da `t/13` e `t/84` | aggiungere crash dopo dispatch prima di mark done |
| Worker crash | non completo end-to-end | staging test con lock running scaduto e reclaim |
| Transaction rollback dopo event/outbox/audit | coperto su thread outbox failure | estendere a report, moderation action, privacy approval |
| Unique conflict su retry | non coperto | test PostgreSQL concorrenti per command_log, bookmark, subscription, report |

## Email lifecycle

Stato verificato:

- verifica email: non esiste workflow completo; `users.email_verified_at` è
  presente, ma la registrazione crea account login-capable;
- reset password: non trovato workflow di reset;
- cambio email sicuro: non trovato workflow con verifica nuova email;
- revoca sessioni: presente in `Identity::Store::revoke_session`, logout,
  validazione server-side session e revoca in privacy erasure.

Rischio: high per account pubblici reali, perché recupero accesso e verifica
identità email sono prerequisiti operativi. È l'unica area funzionale ammessa
prima di nuove feature, ma va trattata come hardening identity, non come
espansione prodotto.

Patch proposta: prima chiudere `critical/high` transazionali; poi introdurre un
workflow minimo verification/reset/change-email con token hashed, scadenza,
single-use e revoca sessioni su cambio password/email.

## Stress test reale richiesto

Gli script esistenti misurano benchmark deterministici e Hypnotoad scaling, ma
non bastano come prova finale 100/500/1000 utenti concorrenti.

Baseline proposta:

1. Preparare staging PostgreSQL con migrazioni e seed:

```sh
script/seed-benchmark --profile medium
script/seed-benchmark --profile hot-thread
```

2. Avviare Hypnotoad con profilo produzione small/medium e metriche abilitate.

3. Eseguire matrice read-heavy con harness esistente:

```sh
script/bench-hypnotoad-scaling --profile medium --worker-set 4,8 \
  --clients 100 --iterations 100 --warmup 10 --json
script/bench-hypnotoad-scaling --profile medium --worker-set 4,8 \
  --clients 500 --iterations 100 --warmup 10 --json
script/bench-hypnotoad-scaling --profile hot-thread --worker-set 4,8 \
  --clients 1000 --iterations 100 --warmup 10 --json
```

4. Coprire route:

- `/categories`
- `/t/018f1004-0001-7000-8000-000000000001`
- `/feed` con sessione utente seeded
- `/search?q=performance`
- `POST /t/:thread_id/reply` con `command_id` unico per richiesta e variante
  retry con stesso `command_id`

5. Report minimo per ogni route:

- p50, p95, p99;
- error rate;
- req/s;
- max/avg DB queries;
- transaction count;
- worker distribution da output Hypnotoad;
- outbox pending/failed/dead-letter prima e dopo;
- RSS e file descriptor.

Go-live gate: nessuna route critica con error rate maggiore di 1%, nessun
duplicato reply/report/job, nessuna crescita outbox non drenata dopo test.

## Prossime patch prioritarie

1. `ID-001`: idempotency guard atomico su `command_log`.
2. `MOD-001` e `MOD-003`: report unique partial, command_id e lock target per
   moderazione.
3. `CM-001` e `CM-002`: upsert atomico bookmark/subscription.
4. `AUD-001`: audit chain state serializzato con test PostgreSQL concorrente.
5. `OUT-001`: crash test outbox più catalogo idempotenza handler.
6. `PRIV-002`: evidenza concorrente PostgreSQL reale in staging.
