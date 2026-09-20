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
- `create_thread`, `create_reply`, `edit_post`, `delete_post`, `edit_thread`, `delete_thread`, e `move_thread` richiedono `command_id` al boundary HTTP e
  usano `command_log` per replay/conflict.
- `record_audit` calcola sempre `record_hash` internamente e include
  `previous_hash` nel payload canonico. `Infrastructure::AuditRecord`
  possiede default, hashing e `verify`; `EventRecorder` resta
  persistenza e lookup della chain.

Punti ancora da chiudere prima del go-live:

- evidenza PostgreSQL concorrente residua per reputation source unique
  (`event_idempotency_keys`, command_log, bookmark, subscription, report,
  moderation hide, privacy approval, audit chain e token consume sono
  coperti da `t/integration/postgres-concurrency.t`);
- failure test con database PostgreSQL reale e worker crash
  (outbox reclaim su lock `running` scaduto).

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

Rischio residuo: chiuso per evidenza PG. `t/integration/postgres-concurrency.t`
esegue due connessioni reali sullo stesso `command_id`.

Patch applicata: `CommandIdempotency::run` cerca e inserisce `command_log`
dentro `txn_do`. Una unique violation su `idempotency_key` ricarica la riga e
restituisce replay o `in_progress` invece di 500. `UniqueConflict->attempt`
usa un savepoint PostgreSQL così il catch non abortisce la `txn_do` esterna.
Test fake in `t/87-command-idempotency.t`; evidenza PG in
`t/integration/postgres-concurrency.t`.

### CM-001: bookmark non atomico

Severità: high.

File coinvolti:

- `lib/GPForum/Service/Community/BookmarkStore.pm`
- `lib/GPForum/Controller/Forum.pm`
- `migrations/007_advanced_community.sql`

Comportamento attuale: `save_bookmark` fa `find_for_user_target`, poi
`create_bookmark` o restore. Il vincolo `bookmarks_user_target_key` impedisce
righe duplicate, ma la sequenza check-then-insert non è retry-safe.

Rischio residuo: chiuso per evidenza PG. `t/integration/postgres-concurrency.t`
prova due `save_bookmark` concorrenti → una riga.
Remove su una riga già soft-deleted non riscrive `deleted_at`.

Patch applicata: `save_bookmark` cattura unique su `bookmarks_user_target_key`,
ricarica la riga vincente e la restore. `remove_bookmark` e
`remove_for_user_target` saltano l'update se `deleted_at` è già valorizzato.
Un secondo save su una riga già attiva con la stessa nota non riscrive
`deleted_at` né `note`.
Test fake in `t/146-concurrency-correctness.t` e `t/24-advanced-community.t`;
evidenza PG in `t/integration/postgres-concurrency.t`.

### CM-002: subscription non atomica

Severità: high.

File coinvolti:

- `lib/GPForum/Service/Notification/SubscriptionStore.pm`
- `lib/GPForum/Controller/Forum.pm`
- `migrations/005_notifications_subscriptions.sql`

Comportamento attuale: `save_subscription` fa find poi insert/restore. Il
vincolo `subscriptions_unique_target` impedisce duplicati, ma non protegge la
risposta applicativa sotto concorrenza.

Rischio residuo: chiuso per evidenza PG. `t/integration/postgres-concurrency.t`
prova due `save_subscription` concorrenti → una riga.
HTTP `command_id` replay evita un secondo mute/unsubscribe con lo stesso
comando; uno store retry senza comando nuovo non riscrive `muted_at` o
`revoked_at` se il valore è già presente.

Patch applicata: `save_subscription` cattura unique su
`subscriptions_unique_target` e restore la riga vincente. Mute e revoke
saltano l'update quando il timestamp è già valorizzato. Un secondo save
su una riga già attiva con la stessa preference non riscrive
`muted_at`, `revoked_at` né `preference`. Test fake in
`t/146-concurrency-correctness.t` e `t/17-notifications.t`; evidenza PG in
`t/integration/postgres-concurrency.t`.

### MOD-001: report duplicati aperti

Severità: high.

File coinvolti:

- `lib/GPForum/Service/Moderation/ReportStore.pm`
- `lib/GPForum/Controller/Forum.pm`
- `migrations/008_moderation_review.sql`
- `migrations/016_security_abuse_hardening.sql`

Comportamento attuale: `create_report` controlla duplicato aperto dentro
transazione, poi inserisce. HTTP mint e richiede `command_id` in
`Community::Workflow`; una risposta persa ritentata con la stessa chiave
riprole da `command_log` e non inserisce una seconda riga. La migrazione
`016` aggiunge un indice parziale su report aperti/triaged, ma non è unique.

Rischio residuo: chiuso per evidenza PG. `t/integration/postgres-concurrency.t`
prova due `create_report` concorrenti → un solo report open.

Patch applicata: `migrations/026_concurrency_uniqueness.sql` aggiunge
`idx_reports_reporter_target_open_unique`. `create_report` cattura il conflitto,
ricarica il report aperto e registra un audit `duplicate_blocked`. Test fake in
`t/146-concurrency-correctness.t`; evidenza PG in
`t/integration/postgres-concurrency.t`.

### MOD-002: transizioni report senza lock riga

Severità: high.

File coinvolti:

- `lib/GPForum/Service/Moderation/ReportStore.pm`
- `lib/GPForum/Controller/Moderation.pm`

Comportamento attuale: assign/release/resolve sono transazionali, bloccano
la riga `reports` con `FOR UPDATE`, e le form HTTP mintano un `command_id`
distinto per comando. Lo store replaya sullo stato (stesso moderatore,
già resolved) senza unique `command_id` sulla tabella `reports`.

Rischio residuo: due `command_id` diversi sullo stesso assign restano
serializzati dal lock; non c'è replay `command_log` se il payload cambia.

### MOD-003: azioni moderation su post/thread senza command-id

Severità: high.

File coinvolti:

- `lib/GPForum/Service/Moderation/ActionStore.pm`
- `lib/GPForum/Controller/Moderation.pm`

Comportamento attuale: hide/restore/lock/unlock sono dentro `txn_do` e, se lo
stato era già quello atteso, restituiscono l'action esistente senza un
secondo insert. I target sono letti con `FOR UPDATE`.

Rischio residuo: chiuso per evidenza PG sullo stesso `command_id`.
`t/integration/postgres-concurrency.t` prova due hide concorrenti → una
action e post `hidden`. Un secondo hide con `command_id` diverso non
inserisce action, evento, audit né outbox se lo stato è già quello atteso
(coperto dai test fake; non rieseguito nel suite PG).

Patch applicata: hide/restore/lock/unlock bloccano il target con `FOR UPDATE`.
Lo stesso `command_id` replay la `moderation_actions` esistente senza nuovo
evento/audit/outbox. Unique parziale `idx_moderation_actions_command_id` in
`migrations/026_concurrency_uniqueness.sql`. Se il target è già nello stato
atteso, lo store restituisce l'action non reversed più recente senza un
secondo insert. Le form HTTP mintano e passano `command_id`. Test fake in
`t/146-concurrency-correctness.t`, `t/25-moderation-review.t` e
`t/86-engineering-correctness.t`; evidenza PG stesso `command_id` in
`t/integration/postgres-concurrency.t`.

### PRIV-001: deletion request duplicabile

Severità: high. Chiuso in codice.

File coinvolti:

- `lib/GPForum/Service/Privacy/DeletionWorkflow.pm`
- `lib/GPForum/Service/Privacy/Record.pm`
- `lib/GPForum/Service/Privacy/Erasure.pm`
- `lib/GPForum/Controller/Privacy.pm`
- `migrations/004_platform_governance.sql`

Comportamento attuale: `request_deletion` richiede `command_id` al boundary
HTTP e, nello store, ricarica una richiesta `pending`/`approved`/`held` per
lo stesso `(resource_type, resource_id, request_type)` dopo `FOR UPDATE`.
Non inserisce una seconda riga e non emette un secondo evento.

Rischio residuo: unique parziale su pending non è più il gap; l'evidenza
PostgreSQL a due connessioni resta da eseguire.

Patch applicata: `migrations/027_privacy_resource_uniqueness.sql` aggiunge
`idx_deletion_requests_open_resource_unique`. `DeletionWorkflow` cattura la
unique violation e ricarica la richiesta aperta. Test fake in
`t/29-privacy-rights.t`.

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
request id ricarica il job esistente e torna idempotente. Se la lookup
del job manca e l'insert viola `idx_erasure_jobs_request_unique`,
`DeletionWorkflow` cattura il conflitto, ricarica il job e non inserisce
una seconda action. Test fake in `t/29-privacy-rights.t`.

Rischio residuo: chiuso per evidenza PG. `t/integration/postgres-concurrency.t`
esegue due approval concorrenti sullo stesso request id → un solo erasure job.

Patch applicata: migration `024`, vincolo DBIC, lock esplicito su approval,
catch UniqueConflict su insert job e test di replay/race in
`t/29-privacy-rights.t`; evidenza PG in `t/integration/postgres-concurrency.t`.

### PRIV-003: retention hold e stato held ripetibili senza replay

Severità: medium. Chiuso in codice.

File coinvolti:

- `lib/GPForum/Service/Privacy/RetentionHoldStore.pm`
- `lib/GPForum/Service/Privacy/DeletionWorkflow.pm`
- `lib/GPForum/Controller/Privacy.pm`

Comportamento attuale: `create_hold` ricarica l'hold attivo per la stessa
risorsa. `hold_deletion` richiede `command_id` HTTP. `hold_request` resta a
quattro argomenti oltre l'invocante. Uno stato già `held` non registra un
secondo evento/action.

Rischio residuo: evidenza PostgreSQL a due connessioni resta da eseguire.

Patch applicata: `migrations/027_privacy_resource_uniqueness.sql` aggiunge
`idx_retention_holds_active_resource_unique`. `RetentionHoldStore` cattura
la unique violation e ricarica l'hold attivo. Test fake in
`t/29-privacy-rights.t`.

### PRIV-005: complete_job con hold attivo ripete action ed event

Severità: medium. Chiuso in codice.

File coinvolti:

- `lib/GPForum/Service/Privacy/DeletionWorkflow.pm`
- `lib/GPForum/Service/Privacy/Completion.pm`

Comportamento attuale: `complete_job` con hold attivo marca la request
`held`, scrive `last_error` sul job e restituisce `retention_hold_active`.
Un secondo `complete_job` mentre l'hold è ancora attivo replay lo stesso
esito (`idempotent`) senza una seconda deletion action né un secondo
evento. Se l'hold termina, un `complete_job` successivo può completare
l'erasure. `hold_request` resta a quattro argomenti oltre l'invocante.

Rischio residuo: evidenza PostgreSQL a due connessioni resta da eseguire.

Patch applicata: `_block_or_replay` in `DeletionWorkflow`, hash
`hold_block_replay` in `Completion`, test in `t/29-privacy-rights.t` e
`t/125-privacy-completion.t`.

### PRIV-006: erasure failure after credential/session revocation

Severità: high. Chiuso in codice.

File coinvolti:

- `lib/GPForum/Service/Privacy/DeletionWorkflow.pm`
- `t/lib/GPForum/Test/EngineeringCorrectness/ResultSet.pm`
- `t/86-engineering-correctness.t`

Comportamento attuale: `complete_job` anonymizza l'utente, revoca
credential e sessioni, poi marca job/request e scrive EventLog/outbox/audit
nella stessa `txn_do`. Un timeout su EventLog, outbox o audit dopo la
revoca ripristina email, `deleted_at`, `revoked_at` e lascia il job
`pending`. Un `complete_job` successivo completa erasure e revoca.

Rischio residuo: evidenza PostgreSQL reale del rollback resta da eseguire.

Patch applicata: `ResultSet->all` sul fake schema di correttezza; test di
timeout e retry in `t/86-engineering-correctness.t`.

### PRIV-004: export request privacy duplicabile

Severità: medium. Chiuso in codice.

File coinvolti:

- `lib/GPForum/Service/Portability/ExportBundleBuilder.pm`
- `lib/GPForum/Controller/Privacy.pm`
- `migrations/010_import_export.sql`

Comportamento attuale: `create_request` richiede `command_id` HTTP e ricarica
una export `pending` per lo stesso requester/subject/type/format. Completare
una request già `completed` resta idempotente. Lo stesso `command_id` dopo
complete replay da `command_log` e non apre un secondo bundle.

Rischio residuo: evidenza PostgreSQL a due connessioni resta da eseguire.

Patch applicata: `Privacy::Workflow` wrappa `request_export` con
`CommandIdempotency`. `migrations/027_privacy_resource_uniqueness.sql`
aggiunge `idx_export_requests_pending_unique`. Test in `t/101-privacy-workflow.t`,
`t/62-privacy-web.t` e `t/27-import-export.t`.

### AUD-001: hash-chain audit non serializzata sotto concorrenza

Severità: high.

File coinvolti:

- `lib/GPForum/Infrastructure/EventRecorder.pm`
- `lib/GPForum/Infrastructure/AuditRecord.pm`
- `migrations/002_event_audit.sql`
- `migrations/004_platform_governance.sql`

Comportamento attuale: ogni audit ha `record_hash = sha256(canonical_record)`
e il record canonico include `previous_hash`. Se `previous_hash` non arriva in
input, il recorder legge l'ultimo hash disponibile. Questo rende il singolo
record tamper-evident e verificabile con `verify_audit_record`.

Rischio residuo: chiuso per evidenza PG. `t/integration/postgres-concurrency.t`
esegue due `record_audit` concorrenti → catena lineare senza branch. Errori di
lookup non vengono più inghiottiti.

Patch applicata: `EventRecorder::record_audit` prende
`pg_advisory_xact_lock` prima del lookup. `AuditRecord` hashing è invariato.
Un fallimento di `AuditLog` search si propaga. Test fake in
`t/146-concurrency-correctness.t`; evidenza PG in
`t/integration/postgres-concurrency.t`.

### OUT-001: worker crash dopo dispatch e prima di mark done

Severità: medium. Chiuso in codice.

File coinvolti:

- `lib/GPForum/Service/Outbox/Dispatcher.pm`
- `lib/GPForum/Service/Outbox/ClaimQuery.pm`
- `lib/GPForum/Service/Outbox/FailureType.pm`
- `lib/GPForum/Service/Outbox/Retry.pm`
- `lib/GPForum/Service/Outbox/DomainEventTransport.pm`
- `lib/GPForum/Worker/HandlerIdempotency.pm`
- `lib/GPForum/Worker/EventIdempotencyStore.pm`
- `lib/GPForum/Worker/Handler/*`

Comportamento attuale: claim PostgreSQL usa `FOR UPDATE SKIP LOCKED`, stato
`running`, `locked_by` e `locked_until`. Crash prima di `done` rende il messaggio
riclamabile dopo lock scaduto. Questo evita perdita silenziosa.

`DomainEventTransport` wrappa ogni handler catalogato e il fallback realtime
con `IdempotentJobRunner`. Le chiavi sono `worker.<name>:{event_id}`.
`EventIdempotencyStore` inserisce in `event_idempotency_keys` solo su
`mark_done`; `begin` e `mark_failed` non persistono. Un crash dopo `begin` e
prima di `handle` non salta il retry. Un crash tra `transport->dispatch` e
`_mark_done` rilancia il messaggio; gli handler già completati risultano
`skipped`. `IdentityMail` non è skip-wrapped: un retry dopo send e prima di
`mark_done` reinvia dalla payload outbox, perché EventLog non ha il token
raw.

Rischio residuo: evidenza PostgreSQL concorrente sullo store chiavi ancora da
eseguire. Notification fanout resta coperto anche da
`notification.reply:{event_id}`.

Patch applicata: catalogo `HandlerIdempotency`, store insert-on-done, wrap
transport/bootstrap, replay e crash test in
`t/150-outbox-handler-idempotency.t`.

### OUT-002: worker crash tra claim e dispatch

Severità: medium. Chiuso in codice.

File coinvolti:

- `lib/GPForum/Service/Outbox/Dispatcher.pm`
- `t/84-outbox-concurrent-dispatcher.t`

Comportamento attuale: `claim_ready_batch` marca la riga `running` con
`locked_until` prima di `transport->dispatch`. Un crash in quel tratto non
consegna il payload. Un altro worker non prende un lock ancora fresco. Dopo
la scadenza del lock la riga è riclamata e consegnata una sola volta.

Rischio residuo: evidenza PostgreSQL reale del reclaim su lock scaduto.

Patch applicata: test claim-then-crash-then-reclaim in
`t/84-outbox-concurrent-dispatcher.t`.

### REP-001: reputation event duplicabile sotto race

Severità: medium. Chiuso in codice.

File coinvolti:

- `lib/GPForum/Service/Community/ReputationLedger.pm`
- `lib/GPForum/Schema/Result/ReputationEvent.pm`
- `lib/GPForum/Worker/Handler/ReputationUpdate.pm`
- `migrations/028_reputation_source_uniqueness.sql`
- `migrations/029_reputation_source_required.sql`

Comportamento attuale: `record_event` ricarica un evento esistente per
`(user_id, source_type, source_id)` prima di inserire. Un unique index
`idx_reputation_events_source_unique` copre ogni riga; `source_id` è `NOT
NULL`. Eventi senza `source_id` non applicano il delta. Il worker usa
`aggregate_id` o, se manca, `event_id`. Una unique violation ricarica
l'evento e non applica di nuovo il delta allo snapshot.

Rischio residuo: evidenza PostgreSQL a due connessioni resta da eseguire.

Patch applicata: migration `028` e `029`, vincolo DBIC, skip senza source,
fallback `event_id` e test fake in `t/24-advanced-community.t` e
`t/149-reputation-update-handler.t`.

## Matrice idempotenza scritture

| Operazione | Retry safe | Network retry safe | Double click safe | Job retry safe | Stato |
| --- | --- | --- | --- | --- | --- |
| `create_thread` | sì per comando completato | sì, unique `command_log` replay | sì con stesso `command_id` | n/a | chiuso in codice |
| `create_reply` | sì per comando completato | sì, unique `command_log` replay | sì con stesso `command_id` | n/a | chiuso in codice |
| `edit_post` | sì per comando completato | sì, unique `command_log` replay + skip stesso `source_hash` | sì con stesso `command_id`; store skip se il body hash coincide | n/a | chiuso in codice |
| `delete_post` | sì per comando completato | sì, unique `command_log` replay | sì con stesso `command_id` | n/a | chiuso in codice |
| `edit_thread` | sì per comando completato | sì, unique `command_log` replay + skip titolo/slug invariati | sì con stesso `command_id`; store skip se titolo e slug coincidono | n/a | chiuso in codice |
| `delete_thread` | sì per comando completato | sì, unique `command_log` replay | sì con stesso `command_id` | n/a | chiuso in codice |
| `move_thread` | sì per comando completato | sì, unique `command_log` replay + skip stessa categoria | sì con stesso `command_id`; store skip se la categoria coincide | n/a | chiuso in codice |
| `report` | sì, `command_id` HTTP + `command_log` | sì, unique command + unique reporter/target | sì con stesso `command_id` | n/a | chiuso in codice |
| `bookmark` | sì, `command_id` HTTP + `command_log` | sì, unique command + unique restore | sì con stesso `command_id` | n/a | chiuso in codice |
| `attachment upload` | sì, `command_id` HTTP + `command_log` | sì, unique command | sì con stesso `command_id` | n/a | hash senza bytes |
| `attachment delete` | sì, `command_id` HTTP + `command_log` | sì, unique command + already-deleted | sì con stesso `command_id` | n/a | chiuso in codice |
| `subscribe` | sì, `command_id` HTTP + `command_log` | sì, unique command + unique restore | sì con stesso `command_id` | n/a | chiuso in codice |
| `thread read marker` | sì, `command_id` HTTP + `command_log` | sì, unique command + unique `(user_id, thread_id)` + upsert monotonic + skip se non avanza | sì con stesso `command_id`; store skip se la posizione non avanza o se la unique race ricarica un marker già sufficientemente avanzato | n/a | chiuso in codice |
| `admin role/permission/category` | sì, `command_id` HTTP + `command_log` | sì, unique command + skip category invariata + unique role/permission/attach/category/space/binding | sì con stesso `command_id`; store skip se i campi coincidono; unique race riusa la riga | n/a | chiuso in codice |
| `moderation assign/resolve` | sì, `command_id` HTTP + `command_log` | sì, unique command + `FOR UPDATE` | sì con stesso `command_id` | n/a | chiuso in codice |
| `moderation hide/restore/lock/unlock` | sì, `command_id` HTTP + `command_log` | sì, lock + unique command | sì con stesso `command_id` | n/a | store e form HTTP chiusi |
| `moderation reverse` | sì, `command_id` HTTP + `command_log` | sì, unique command + stato `reversed_at` | sì con stesso `command_id` | n/a | arity store ferma a 4 |
| `moderation suspend/revoke` | sì, `command_id` HTTP + `command_log` | sì, unique command + active reuse | sì con stesso `command_id`; retry revoke completa restore utente, skip se già active | n/a | arity `revoke_suspension` ferma a 4 |
| `privacy deletion request` | sì, `command_id` HTTP + replay richiesta aperta | sì, unique parziale + catch | sì stessa risorsa aperta | n/a | chiuso in codice |
| `privacy approval` | sì per retry completato | sì, unique job + catch | sì, riusa job esistente; unique race fake senza seconda action | n/a | mitigato con lock e unique job; evidenza PG a due connessioni residua |
| `privacy erasure completion` | sì per job `done` o blocco hold già scritto | sì, rollback se EventLog/outbox/audit fallisce dopo revoca | sì, replay blocco o complete; retry incompleto restaura `held`/`last_error` senza secondo evento; retry job `done` completa la request se ancora aperta | sì, replay blocco o complete | chiuso in codice |
| `privacy hold` | sì, `command_id` HTTP + replay hold attivo | sì, unique parziale + catch | sì stessa risorsa attiva | n/a | arity `hold_request` ferma a 5 |
| `privacy export request` | sì, `command_id` HTTP + `command_log` dopo complete | sì, unique pending + catch | sì stesso comando o stesso pending | n/a | chiuso in codice |
| `identity login` | sì, `command_id` HTTP + `command_log` | sì, unique command | sì con stesso `command_id` | n/a | chiuso in codice |
| `identity logout` | sì, `command_id` HTTP + `command_log` | sì, unique command | sì con stesso `command_id`; store skip se già revocata | n/a | chiuso in codice |
| `identity register` | sì, `command_id` HTTP + `command_log` | sì, unique command + unique username/email | sì con stesso `command_id`; unique race → errori duplicate | n/a | chiuso in codice |
| `identity password change` | sì, `command_id` HTTP + `command_log` | sì, unique command + skip stessa secret | sì con stesso `command_id`; store skip se la secret coincide | n/a | chiuso in codice |
| `identity locale change` | sì, `command_id` HTTP + `command_log` | sì, unique command + skip stesso valore | sì con stesso `command_id`; store skip se locale già uguale | n/a | guest cookie-only |
| `identity theme change` | sì, `command_id` HTTP + `command_log` | sì, unique command + skip stesso valore | sì con stesso `command_id`; store skip se theme già uguale | n/a | guest cookie-only |
| `notification preferences` | sì, `command_id` HTTP + `command_log` | sì, unique command + skip stessi canali | sì con stesso `command_id`; store skip se i canali coincidono | n/a | locale/theme su POST `/settings` mintano chiavi proprie |
| `identity email change complete` | sì, `command_id` HTTP + `command_log` | sì, unique command + token `used_at` + skip stessa email già verificata | sì con stesso `command_id`; store skip se l'email coincide | n/a | chiuso in codice |
| `identity email verification complete` | sì, `command_id` HTTP + `command_log` | sì, unique command + token `used_at` + skip già verificato | sì con stesso `command_id`; store skip se già active e verificato | n/a | chiuso in codice |
| `identity password reset complete` | sì, `command_id` HTTP + `command_log` | sì, unique command + token `used_at` + skip rotazione stessa secret | sì con stesso `command_id`; store skip della rotazione se la secret coincide; le sessioni restano revocate | n/a | chiuso in codice |
| `identity password reset request` | sì, `command_id` HTTP + `command_log` | sì, unique command + unique unused `(user_id, token_type)` | sì con stesso `command_id`; `command_id` diverso ruota il token unused | n/a | chiuso in codice |
| `identity email change request` | sì, `command_id` HTTP + `command_log` | sì, unique command + unique unused `(user_id, token_type)` + skip email già verificata | sì con stesso `command_id`; store skip se l'email coincide; `command_id` diverso ruota il token unused | n/a | chiuso in codice |
| `identity email verification request` | sì, `command_id` HTTP + `command_log` | sì, unique command + unique unused `(user_id, token_type)` | sì con stesso `command_id`; `command_id` diverso ruota il token unused | n/a | chiuso in codice |
| `outbox dispatch` | at-least-once | n/a | n/a | sì, chiavi `worker.<name>:{event_id}` | chiuso in codice |
| `reputation record` | sì per stessa source | sì, unique NOT NULL + catch | sì stessa source | sì, stessa source | `source_id` obbligatorio |

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
| DB unavailable su readiness/realtime | coperto in parte da readiness/realtime | write route `create_reply`, report, hide e export ora 503 senza leakage (`t/152`) |
| DB timeout in transazione write | timeout su insert EventLog, outbox e audit con rollback | `t/86-engineering-correctness.t` |
| Minion unavailable | fail-closed se `GPFORUM_MINION_ENABLED=1` e backend assente; `gpforum-outbox-dispatch` salta Minion | `t/83-outbox-worker-wiring.t` |
| Outbox retry/dead letter | cancelled + dead-letter; permanent fail-fast; no re-claim | `t/13-outbox-dispatcher.t`, `docs/ops/dead-letters.md` |
| Worker crash | crash tra claim e dispatch, o tra dispatch e mark done | `t/84-outbox-concurrent-dispatcher.t`, `t/150-outbox-handler-idempotency.t`; staging reclaim su lock scaduto |
| Transaction rollback dopo event/outbox/audit | coperto su thread, report, hide e approval outbox failure | `t/86-engineering-correctness.t` |
| Unique conflict su retry | non coperto | test PostgreSQL concorrenti per command_log, bookmark, subscription, report |
| Errore dopo commit HTTP | retry identico create_reply, thread, report, hide, export | `t/153-lost-response-retry.t` |

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

1. Staging: reclaim outbox su lock `running` scaduto con PostgreSQL reale
   (claim-then-crash reclaim resta coperto in `t/84-outbox-concurrent-dispatcher.t`;
   manca evidenza su PostgreSQL reale oltre al mock).
2. Reputation source unique: evidenza PostgreSQL concorrente ancora aperta
   (`event_idempotency_keys` è coperto da `t/integration/postgres-concurrency.t`).
