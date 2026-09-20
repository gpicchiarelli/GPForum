# GPForum longevity architecture review

Data: 2026-06-02.

Ruolo: Principal Engineer incaricato di valutare mantenibilità, evolvibilità,
costo futuro, complessità architetturale e debito tecnico su un orizzonte di
5-10 anni.

Non è una security review e non propone nuove funzionalità. Le valutazioni
derivano dal codice ispezionato in `lib`, `t`, `migrations`, `deploy`,
`.github/workflows` e dagli script di gate architetturale.

## Evidenze principali dal codice

- `lib` contiene 248 moduli Perl.
- I layer più grandi sono `Service` con 102 moduli e 18.741 righe,
  `Controller` con 12 moduli e 5.444 righe, `Command` con 10 moduli e 5.177
  righe, `Schema::Result` con 58 result class e 3.146 righe.
- I controller più grandi sono `Controller::Forum` con 1.360 righe,
  `Controller::Identity` con 1.157 righe, `Controller::Moderation` con 651
  righe e `Controller::Admin` con 622 righe.
- I servizi più grandi sono `Service::Attachment::Store` come facade di
  persistenza sopra `Record`, `DownloadAccess`, `Lifecycle` e `Event`,
  `Service::Privacy::DeletionWorkflow` come facade sopra `Record`, `Erasure`,
  `Completion` e `Event`, `RetentionHoldStore` come persistenza hold sopra
  `Event`,
  e `Service::Outbox::Dispatcher` come facade sopra `FailureType`, `Retry` e
  `ClaimQuery`. `Identity::Store` è un facade
  di 317 righe sopra store dedicati, con `Identity::Event` sotto `Audit`.
- `Domain` oggi contiene sostanzialmente solo `EventEnvelope`; il dominio reale
  è espresso soprattutto in service, store, workflow e schema DBIC.
- Le migrazioni sono 25; le più dense sono `004_platform_governance.sql`,
  `003_forum_projection.sql`, `001_core_identity.sql` e
  `002_event_audit.sql`.
- `t` contiene 87 test file top-level e 106 helper sotto `t/lib`, per circa
  30.115 righe di test/helper.
- `script/architecture-check` e i test `t/34-architecture-discipline.t`,
  `t/75-architecture-foundation.t`, `t/86-engineering-correctness.t` passano.
- Non ho trovato dipendenze dirette dai servizi verso controller/view/web o
  accesso DBIC diretto nei controller; questa è una proprietà positiva reale.

## Sintesi

GPForum è un modular monolith molto più ordinato della media: composition root
esplicita, DBIC schema ricco, service layer ampio, outbox, audit/event log,
query budget, test estesi e deploy templates. Questo gli dà una base concreta
per durare.

Il rischio principale non è la mancanza di architettura, ma l'eccesso di
superficie già presente rispetto al nucleo forum: identity avanzata, privacy,
moderation, realtime, plugin, portability, OS runtime, benchmark e governance
sono tutti nel monolite. Se questa superficie cresce senza estrarre boundary
applicativi più stabili, il costo futuro salirà in modo non lineare.

La stima onesta: GPForum può restare mantenibile 5 anni senza riscrittura se
resta un modular monolith e se nei prossimi 12 mesi si riducono controller
grandi, identity store e workflow troppo larghi. Se invece si aggiungono
federazione, API pubbliche, mobile, plugin esterni e multi-site senza questi
refactor, il rischio di riscrittura parziale diventa alto.

## Valutazione per area

| Area | Punteggio | Debito | Motivazione | Rischio | Costo futuro |
| --- | ---: | --- | --- | --- | --- |
| Architettura | 8.0/10 | ARCHITECTURAL | `GPForum.pm` delega a bootstrap mirati; `Service`, `Web`, `ViewModel`, `Worker`, `Schema` sono separati; i controller non usano DBIC direttamente. | Composition manuale via helper Mojolicious e bootstrap molto larghi possono diventare un service locator difficile da governare. | Medio: cresce con ogni nuovo workflow. |
| Dominio | 7.0/10 | STRATEGIC | Concetti di forum, identity, moderation, privacy, event/outbox sono riconoscibili e coerenti. | Il dominio è implicito in store/schema/stringhe di stato; `Domain` è sottile e non contiene aggregate/workflow semantics. | Medio-alto se arrivano federation/API/plugin. |
| Database | 8.0/10 | OPERATIONAL | Schema PostgreSQL forte: vincoli, indici, unique key, partizioni per event/audit/notifications, read model e query budgets. | Crescita dati richiede lifecycle di partizioni, archiviazione, retention e restore operativi più espliciti; alcune migrazioni iniziali sono molto dense. | Medio fino a 10k utenti, alto a 100k. |
| Controller | 5.5/10 | CODE QUALITY | I controller rispettano abbastanza il boundary DB, ma `Forum` e `Identity` sono troppo grandi e duplicano error/render/auth/CSRF/HTML-JSON. | Ogni variazione di UX/API può toccare file grandi, aumentare branching e rendere fragili i test web. | Alto nei prossimi 12 mesi. |
| Workflow | 7.0/10 | ARCHITECTURAL | `PostingWorkflow`, outbox dispatcher e idempotency service sono buoni segnali; transazioni sono concentrate negli store. | Identity, privacy e moderation mescolano troppi casi in store/workflow larghi; alcuni workflow restano orchestrati nei controller. | Medio-alto. |
| Testing | 8.0/10 | OPERATIONAL | Suite ampia, CI severa, coverage, architecture gates, query budget, benchmark smoke e molte regressioni business. | Molti test sono fixture/test-double e contratti testuali; il costo manutentivo cresce e può mancare evidenza DB reale su nuove concorrenze. | Medio. |
| Performance architecture | 7.0/10 | ARCHITECTURAL | Keyset pagination, query budget, indici hot path, FTS/trigram search, cache locale TTL/tagged. | Cache process-local, invalidazione limitata e search dentro PostgreSQL possono diventare colli di bottiglia a scala alta. | Medio a 10k, alto a 100k. |
| Operazioni | 7.5/10 | OPERATIONAL | Config validata, request id, metrics/readiness, systemd/nginx/freebsd/launchd, preflight e CI con PostgreSQL. | Profili ambiente e rollback sono più contratti/runbook che automazione completa; debug multi-process richiederà disciplina operativa. | Medio. |
| Evoluzione futura | 6.5/10 | STRATEGIC | Modular monolith adatto a evoluzione graduale; plugin registry e bootstrap boundaries esistono. | OAuth/OIDC, API pubbliche, mobile, multi-site e federation chiedono boundary più stabili di quelli attuali. | Alto se si cresce senza refactor. |

## Architettura

### Cosa funziona

- `GPForum.pm` è un composition root leggibile: costruisce config/runtime e
  registra bootstrap specifici.
- I bootstrap separano le famiglie principali: Core, Security, Operations,
  Identity, Discovery, Forum, Workers, Admin, Moderation, Privacy, Routes.
- I controller non accedono direttamente a `DBIx::Class` resultset; passano da
  helper/service.
- I service non dipendono dai controller o dalle view.
- I gate architetturali sono eseguibili e passano.

### Costo futuro

Il sistema usa helper Mojolicious come contenitore di dipendenze. Oggi è
pragmatico; tra 5 anni può diventare opaco, perché dipendenze e lifetime sono
distribuiti fra `Bootstrap::*` e i controller. Il file
`Bootstrap::Forum` registra molte dipendenze eterogenee: forum, attachment,
community, notification e search. Questa scelta resta accettabile finché il
prodotto rimane monolite SSR, ma diventa costosa se arrivano API/mobile o
multi-site.

### Debito

ARCHITECTURAL: introdurre un boundary applicativo più esplicito per workflow
write/read critici prima di estendere le capability esterne.

## Dominio

### Cosa funziona

- Nomi principali coerenti: `Thread`, `Post`, `PostBody`, `PostRevision`,
  `Report`, `ModerationAction`, `DeletionRequest`, `ErasureJob`,
  `OutboxMessage`, `EventLog`, `AuditLog`.
- Il concetto di event/outbox è consistente nei writer principali.
- `PostingWorkflow` è un buon confine applicativo per thread/reply.
- I read model sono separati dai writer in diversi casi.

### Costo futuro

Il dominio non è ancora espresso come modello di aggregate stabile. Le regole
vivono in store e controller, spesso come stringhe di stato:
`visible`, `hidden`, `locked`, `pending`, `approved`, `held`, `done`.
Questo non è sbagliato per un MVP, ma rende più costoso aggiungere varianti di
workflow senza rompere casi esistenti.

Il modulo `Domain` è troppo piccolo rispetto alla quantità di semantica reale.
Non serve creare oggetti domain ovunque, ma i comandi principali dovrebbero
diventare contratti applicativi chiari e testabili.

### Debito

STRATEGIC: formalizzare command/result/event contracts dei workflow principali
prima di introdurre integrazioni esterne.

## Database

### Cosa funziona

- DBIC schema ampio e nominato in modo comprensibile.
- Vincoli importanti presenti: unique su utenti, session hash, post position,
  revision number, bookmark/subscription target, outbox idempotency, command log
  idempotency.
- Indici hot path presenti per thread, post, search, outbox, report, sessioni.
- Event, audit e notifications sono predisposti a partizioni range su
  `created_at`.
- `query-plan-check` e `query-plan-evidence` esistono come strumenti di
  controllo.

### Costo futuro

Le tabelle append-only e semi-append-only diventeranno il punto operativo più
costoso: `event_log`, `audit_log`, `notifications`, `outbox_messages`,
`dead_letters`, `search_documents`, `post_revisions`, `rate_limit_buckets`.
Il codice ha già i concetti, ma non vedo nel codice una gestione completa del
partition lifecycle, archiviazione, retention per ogni tabella o rotazione dei
dati freddi.

A 100.000 utenti, PostgreSQL può ancora essere il centro del sistema, ma solo
con partizioni attive, vacuum/retention misurati, search dimensionata e
separazione chiara dei job.

### Debito

OPERATIONAL: creare lifecycle operativo di partizioni/retention/archiviazione
prima che il volume lo imponga.

## Controller

### Cosa funziona

- I controller delegano molto a service/view model.
- Non ho trovato accesso diretto a resultset DBIC nei controller.
- `Forum` usa `PostingWorkflow` per create_thread/create_reply/edit_post/delete_post/restore_post/edit_thread/delete_thread/restore_thread/move_thread invece di
  inserire direttamente.

### Costo futuro

`Controller::Forum` e `Controller::Identity` sono il debito più evidente.
Esempi dal codice:

- `Controller::Forum` ha 1.360 righe e gestisce read pages, writes, feed,
  bookmark, subscription, report, search, autocomplete, cache rendering, error
  payload, CSRF, rate limit e suspension checks.
- `Controller::Identity` ha 1.157 righe e include login, register, reset,
  settings, email confirmation, profile e molti helper di rendering/route.
- `_render_payload`, `_render_error`, `_csrf_failure`, `_forbidden`,
  `_bad_request`, `_current_user_id` e pattern simili sono duplicati in più
  controller.

Questo non richiede un mega-refactor. Richiede una sequenza controllata:
estrarre prima helper HTTP comuni e command adapters, poi ridurre i metodi più
lunghi.

### Debito

CODE QUALITY: refactor entro 12 mesi. Non per estetica, ma per ridurre costo di
nuove route/API e regressioni sui flussi esistenti.

## Workflow

### Cosa funziona

- `PostingWorkflow` è una buona evoluzione rispetto a controller business logic.
- `CommandIdempotency` rende esplicito il concetto di comando/replay.
- `PostStore` alloca posizione dentro transazione e blocca il thread via
  `FOR UPDATE`.
- `Outbox::Dispatcher` usa claim batch PostgreSQL con `FOR UPDATE SKIP LOCKED`.
- `DeletionWorkflow` contiene idempotenza su approval/job e controllo hold.

### Costo futuro

La qualità non è uniforme:

- forum posting ha workflow applicativo;
- moderation è ancora principalmente `ActionStore`;
- identity è un unico store largo per credenziali, sessioni, token, preferenze
  e audit;
- privacy deletion è un workflow dedicato ma già complesso;
- bookmark/subscription sono store semplici con logica check-then-write.

Per mantenibilità a 5 anni, i write workflow devono convergere verso una forma
comune: command object, authorization decision, idempotency, transaction,
event/audit/outbox, response.

### Debito

ARCHITECTURAL: uniformare i write workflow critici senza creare framework.

## Testing

### Cosa funziona

- Suite ampia: 87 file top-level e 106 helper.
- CI include syntax, perltidy, perlcritic, migrations, seed, query budget,
  architecture check, query plan, tests, benchmark smoke, Hypnotoad e coverage.
- Esistono test di architettura e engineering correctness, non solo unit test.
- Molti moduli hanno test mirati e fixture helper riusabili.

### Costo futuro

Il costo di manutenzione della suite è già significativo. Alcuni test sono
molto lunghi (`t/05-database.t`, `t/09-prompt-alignment.t`,
`t/72-forum-bootstrap-workflow.t`) e alcuni verificano contratti tramite testo
o regex. Questi gate sono utili, ma possono diventare fragili quando il design
cambia legittimamente.

Il rischio principale è falso comfort: test doubles e fixture rapide non
sostituiscono test PostgreSQL concorrenti o prove operative reali quando si
toccano command log, audit chain, outbox, privacy e moderation.

### Debito

OPERATIONAL: mantenere i test veloci, ma aggiungere test DB-backed solo sui
punti dove il rischio reale lo giustifica.

## Performance architecture

### Cosa funziona

- Paginazione keyset in lettori forum/bookmark.
- Query budget catalog e osservazione DB request-level.
- Search usa PostgreSQL FTS/trigram e limiti bounded.
- Cache locale con TTL, tag, LRU-like eviction.
- Public HTTP cache solo per GET/HEAD guest e `Vary: Accept, Cookie`.

### Costo futuro

La cache è per-processo. Con più worker/processi, ogni processo ha una vista
separata e l'invalidazione non è distribuita. Oggi questo va bene perché la
cache è trattata come acceleratore deperibile. A 10k utenti può ancora andare
se TTL e query sono sani. A 100k utenti, serve decidere se rimanere con cache
locale prudente o introdurre una cache condivisa solo per letture ben definite.

Search dentro PostgreSQL è una scelta giusta all'inizio. A scala alta può
restare valida, ma solo con budget, indici e dataset evidence; non va
sostituita preventivamente.

### Debito

ARCHITECTURAL: mantenere cache locale finché basta; preparare un adapter cache
solo quando metriche reali lo richiedono.

## Operazioni

### Cosa funziona

- `Config` valida runtime, OS, secret production e profili Hypnotoad.
- `Bootstrap::Operations` installa request id, DB query stats, budget headers,
  metrics snapshot, readiness e rate limiter.
- Deploy templates per systemd/nginx/freebsd/launchd esistono.
- CI usa PostgreSQL service e applica migrazioni.

### Costo futuro

Operations è abbastanza buono per un team piccolo. Il costo futuro nasce da:

- profili ambiente non ancora separati come oggetti versionati;
- rollback/restore ancora più runbook che automazione;
- query budget endpoint mapping manuale in `Bootstrap::Operations`;
- readiness che dipende anche da cataloghi applicativi da sincronizzare;
- deployment cross-platform che aumenta superficie di supporto.

### Debito

OPERATIONAL: ridurre drift tra dev/staging/prod con profili espliciti e
evidence automatizzata.

## Evoluzione futura

### 1.000 utenti

Probabilità di restare mantenibile: alta.

Il monolite SSR, PostgreSQL, DBIC, query budget e cache locale sono coerenti.
Il costo principale sarà operativo: backup, mail, staging, metriche e piccole
regressioni controller.

### 10.000 utenti

Probabilità di restare mantenibile: medio-alta.

Servono disciplina su:

- indici e query plan su dataset reale;
- outbox throughput;
- search projection;
- cache TTL;
- moderation e privacy workflow;
- riduzione controller.

Non serve una riscrittura. Serve evitare feature spread.

### 100.000 utenti

Probabilità di restare mantenibile senza refactor sostanziali: media-bassa.

Il sistema può ancora essere un modular monolith, ma richiede:

- lifecycle partizioni/retention;
- search e feed più misurati;
- API/read model più espliciti;
- cache/invalidation strategy più formale;
- outbox/worker topology controllata;
- profili deploy e observability multi-process/multi-host.

Non è il numero utenti in sé a rompere il progetto; è la combinazione di volume
dati, workflow privacy/moderation e integrazioni esterne.

## Impatto di evoluzioni strategiche

| Evoluzione | Impatto sulla codebase | Rischio se fatta ora | Nota tecnica |
| --- | --- | --- | --- |
| Federazione | Molto alto | Alto | Richiede event contracts, identity mapping, moderation propagation e retry semantics molto più rigidi. |
| OAuth/OIDC | Medio | Medio | Integrabile, ma `Identity::Store` va separato in credenziali/sessioni/token/profile. |
| API pubbliche | Alto | Alto | I controller SSR non sono un buon boundary API stabile; serve adapter API su service/workflow. |
| Mobile app | Alto | Medio-alto | Simile alle API pubbliche; richiede payload/versioning e auth/session contracts più espliciti. |
| Multi-site | Molto alto | Alto | Lo schema non mostra tenancy globale; aggiungerla tardi è costoso. |
| Plugin system | Alto | Alto | Registry/hook dispatcher sono piccoli; farli diventare ecosistema prima di stabilizzare contratti core sarebbe rischioso. |

## Debiti prioritari

| Debito | Tipo | Orizzonte | Costo se ignorato |
| --- | --- | --- | --- |
| Controller grandi e helper HTTP duplicati | CODE QUALITY | 0-12 mesi | Alto |
| `Identity::Store` troppo largo | ARCHITECTURAL | fatto: facade su store dedicati | Basso |
| Workflow write non uniformi | ARCHITECTURAL | 0-12 mesi | Medio-alto |
| Domain model troppo implicito | STRATEGIC | 12-24 mesi | Medio-alto |
| Partition/retention lifecycle | OPERATIONAL | prima di crescita dati | Alto |
| Cache/invalidation process-local | ARCHITECTURAL | solo se scala | Medio |
| Plugin/federation/API contracts prematuri | STRATEGIC | solo se roadmap conferma | Alto |
| Test lunghi/fragili a regex | OPERATIONAL | continuo | Medio |

## Cosa NON cambiare

- Non sostituire Mojolicious/SSR: è coerente col prodotto e mantiene il sistema
  semplice.
- Non introdurre microservizi: la codebase beneficia ancora del modular
  monolith.
- Non sostituire PostgreSQL/DBIC senza evidenza: lo schema è una forza, non un
  limite immediato.
- Non aggiungere cache distribuita, Redis o search engine esterno senza
  saturazione misurata.
- Non trasformare i bootstrap in un framework DI complesso; basta rendere più
  espliciti i workflow principali.
- Non espandere plugin/federazione/API pubbliche prima di stabilizzare i
  boundary applicativi.

## Cosa rifattorizzare entro 12 mesi

1. Estrarre helper HTTP comuni in `GPForum::Web::*`:
   auth required, CSRF failure, JSON/HTML error payload, redirect helpers,
   permission denial e current user.
   `Web::Guard`, `Web::Access`, `Web::RealtimeAccess`, `Web::CookieSession`,
   `Web::PublicCacheAccess`, `Web::HomeAccess`, `Web::IdentityAccess`,
   `Web::DiscoveryAccess`, `Web::ForumAccess`, `Web::AttachmentAccess`,
   `Web::NotificationAccess`, `Web::ModerationAccess`, `Web::PrivacyAccess`,
   `Web::AdminAccess` e `Web::OperationsAccess` coprono i contratti
   condivisi, la home `home_unavailable`, gli errori testuali di identity, i
   limiti/render dei documenti crawler, i limiti/validazioni HTTP del forum,
   i limiti/filename HTTP degli attachment, i limiti HTTP delle notifiche, i
   limiti/filtri HTTP della moderation, i limiti/conflict HTTP della privacy,
   i limiti HTTP admin, gli hash realtime connect/subscribe e il token
   `/metrics`. Gli status di successo delle write HTTP (admin catalog/binding,
   moderation content/queue/suspension, privacy review, community
   bookmark/subscription) vivono sugli stessi oggetti `Web::*Access`.
2. Ridurre `Controller::Forum`:
   separare read pages, write commands, community actions e search handlers.
3. Ridurre `Controller::Identity`:
   separare login/session, password lifecycle, email lifecycle, settings e
   profile rendering.
4. Separare `Identity::Store`:
   fatto. Il facade delega a `CredentialStore`, `SessionStore`, `TokenStore`,
   `Audit`, `PreferenceStore`, `AccountStore`, `AuthStore` e
   `RegistrationStore`, con `Identity::Workflow` sopra. `Password`,
   `SessionToken` e `Service::Id` caricano `Crypt::URandom` in modo lazy;
   lo store e i collaboratori credential/session/token caricano
   `Service::Id` in modo lazy.
5. Uniformare write workflow:
   command input, idempotency, transaction, event/audit/outbox, response.
   Hashing audit è in `Infrastructure::AuditRecord`; `EventRecorder`
   resta persistenza EventLog/Outbox/AuditLog e lookup della chain, e
   carica `Service::Id` in modo lazy insieme a `Outbox::MessageBuilder` e
   agli store event-backed che lo usavano solo per il default.
   Classificazione, retry e SQL di claim outbox sono in `FailureType`,
   `Retry` e `ClaimQuery`. Envelope e payload attachment sono in
   `Attachment::Event`. Policy di orphan cleanup attachment è in
   `Attachment::Lifecycle`, inclusi i cap di fetch dei link. Envelope e payload privacy sono in `Privacy::Event`,
   inclusi i retention hold. Envelope e audit identity sono in
   `Identity::Event`, inclusi login e logout. Envelope e audit delle
   moderation action sono in
   `Moderation::Event`, inclusi report e suspension. Audit admin di catalog
   e binding sono in `Admin::Event`.
6. Rendere espliciti i profili operativi:
   dev, staging, production-small, production-medium.
7. Versionare il lifecycle DB:
   partizioni, retention, archiviazione, restore evidence.

## Cosa rifattorizzare solo se il progetto cresce

- Adapter cache condivisa oltre `LocalCache`.
- Search backend esterno o search service separato.
- API versioning layer per mobile/pubblico.
- Multi-site tenancy.
- Plugin runtime isolato.
- Federazione/event bridge.
- Sharding o separazione worker/read model.

Questi lavori sono costosi e non vanno anticipati senza pressione reale.

## Cosa è già sufficientemente buono

- Modular monolith come forma generale.
- PostgreSQL come database primario.
- DBIC result classes e migrazioni tracciate.
- Outbox/retry/dead-letter come pattern.
- Query budget e query-plan evidence.
- Security/operations bootstrap centralizzati.
- ViewModel separati dalle template.
- CI con Perl::Critic/perltidy/syntax/test/coverage/benchmark.
- Hypnotoad/systemd/nginx deployment shape.

## Stima finale

Quanto è probabile che GPForum resti mantenibile tra 5 anni senza una
riscrittura?

Stima tecnica: 70%.

Questa probabilità sale verso 80% se il progetto resta focalizzato sul forum
core e completa i refactor entro 12 mesi su controller, identity store e
workflow write.

Scende verso 45-50% se nei prossimi 12-18 mesi vengono aggiunti federazione,
API pubbliche, mobile app, multi-site e plugin ecosystem senza prima rafforzare
i boundary applicativi.

Conclusione: GPForum non ha bisogno di una riscrittura. Ha bisogno di
proteggere il proprio nucleo, ridurre i controller grandi e rendere più
espliciti i workflow applicativi prima che la superficie del prodotto cresca.
