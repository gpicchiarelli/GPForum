# GPForum release-readiness review

Data: 2026-09-20 (refresh post-merge through outbox reclaim / PG evidence
on `main`; earlier baseline 2026-06-02).

Scopo: valutare GPForum dopo le patch di stabilizzazione senza introdurre nuove
funzionalità. Questa review distingue tre livelli: uso locale personale, beta
privata e produzione pubblica.

## Release verdict

| Target | Verdetto | Motivazione tecnica |
| --- | --- | --- |
| LOCAL READY | sì | Suite completa, coverage, migrazioni fresh/upgrade, backup/restore locale, query budget, benchmark smoke/stress locali e security/failure suite sono verdi. |
| PRIVATE BETA READY | no | Mail/moderation/idempotenza e evidenza PG a due connessioni (concurrency, idempotency, outbox reclaim) sono in codice; staging-drill DB + attachment/deploy checklist + stress-load harness sono shippati. Restano evidenza live su staging (SMTP, stress 100+, deploy target). Può reggere solo una alpha privata operator-assisted. |
| PUBLIC PRODUCTION READY | no | Mancano staging rappresentativo end-to-end, numeri stress 100/500/1000 su target, attachment restore drill live e runbook di rollback provato sul target (harness/drill in tree). |

Raccomandazione finale: GPForum è pronto per uso locale personale e per
ulteriore hardening su staging. Non è pronto per beta privata self-service né
per produzione pubblica.

## Patch minime applicate durante la review

| Severità | Patch | File | Rischio mitigato | Test |
| --- | --- | --- | --- | --- |
| HIGH | Qualificati i filtri `me.*` in `PostReader::list_thread_posts` | `lib/GPForum/Service/Forum/PostReader.pm` | 500 su `/t/:thread_id` con PostgreSQL reale per `deleted_at` ambiguo dopo join con `post_bodies` e `users` | `t/21-forum-pagination.t`, `t/31-forum-http-readers.t`, riproduzione DB reale su thread seeded |
| HIGH | Aggiunto `EnvironmentFile=/etc/gpforum/gpforum.env` alle unità systemd | `deploy/systemd/*.service` | Deploy systemd production senza secret/DB env espliciti | `t/18-github-project.t` |
| HIGH | Documentato `script/query-budget --sync` prima della readiness | `docs/DEPLOYMENT.md`, `docs/PRODUCTION_READINESS.md` | Fresh install migrato ma readiness 503 per query budget catalog vuoto | `t/18-github-project.t`, DB reale con `query-budget --sync --check` |

## Go / No-Go table

| Area | Stato | Evidenza | Rischio residuo | Azione richiesta |
| --- | --- | --- | --- | --- |
| Test suite completa | GO | `carton exec script/test` PASS (suite cresciuta oltre la baseline 2026-06-02) | Nessuno bloccante locale | Mantenere in CI |
| Migrazioni fresh install | GO locale | Schema versioni `001`–`036` (36 migrazioni) su `main`; percorso fresh ancora da ripetere su staging target | Non ancora su staging target | Ripetere su staging PostgreSQL uguale alla produzione |
| Migrazioni upgrade | GO locale | Percorso 024→025 storico; successive uniqueness/concurrency (`026`–`036`) presenti nel tree | Upgrade full chain non riprovato end-to-end su staging | Ripetere da snapshot staging/restored attraverso `036` |
| Rollback migrazioni | NO-GO produzione | Documentata strategia forward-fix in `docs/PRODUCTION_READINESS.md` | Rollback non provato con sistema/nginx/systemd reale | Rehearsal forward-fix e restore drill su staging |
| Perl::Critic | GO | `script/perlcritic`: `new_violations=0` | Restano baseline note, non nuove | Non allargare baseline senza review |
| Perltidy | GO | `script/perltidy-check`: PASS | Nessuno | Mantenere gate |
| Coverage | GO | `script/coverage`: PASS (gate) | Alcuni moduli operativi hanno coverage basso, ma gate passa | Aumentare coverage su realtime/controller solo se toccati |
| Benchmark smoke | GO | Fixture e configured benchmark verdi | Numeri locali, non staging | Ripetere con dataset rappresentativo |
| Benchmark stress | PARTIAL | Harness: `script/stress-load` profiles 100/500/1000 on `main`; Hypnotoad scaling hot-thread 2/4 worker PASS; outbox 1k/10k PASS | Staging 100/500/1000 evidence not yet recorded | Run `script/stress-load --profile 100|500|1000` on staging and archive JSON |
| Query budget | GO | `script/query-budget --sync`, `--check`: PASS; route thread max 3 query, budget ok | Catalog deve essere sincronizzato in deploy | Eseguire sync/check dopo ogni migration deploy |
| Query plan | GO | `script/query-plan-check`: `offset_violations=0`; `query-plan-evidence` PASS su small | Dataset locale piccolo | Medium/hot-thread staging evidence |
| Security audit | PARTIAL GO | Security suite mirata PASS | Bot/device anomaly non avanzati | Estendere security tests prima beta |
| Failure mode tests | GO evidence | FM-001–FM-007 + FM-008–FM-010; reclaim OUT-002 chiuso in audit (`t/152`/`t/153`/`t/150`/`t/86`, `t/integration/postgres-{concurrency,idempotency,outbox-reclaim}.t`) | Skip senza DSN; staging reclaim end-to-end ancora manuale | Tenere suite verde con DSN in CI/ops |
| Backup/restore | GO locale / PARTIAL staging | `pg_dump -Fc` / `pg_restore`; `script/staging-drill` per migrate + dump/restore throwaway (MacPorts notes in `docs/ops/staging-drills.md`) | Attachment blobs fuori dal dump; RPO/RTO staging incompleto | Restore drill staging con allegati + deploy |
| Session security | GO | Sessioni server-side, revoca, scadenza, cookie flags e CSRF coperti da suite security | Revoca globale sessioni/device anomaly non avanzata | Accettabile per locale, estendere per beta |
| Rate limiting | GO | PostgreSQL limiter, fallback telemetry e blocked audit coperti | Fallback local memory non cluster-wide | In beta usare PostgreSQL store e monitorare fallback |
| Email lifecycle | GO codice | Reset/cambio password/email, token monouso, `Identity::Mailer`, `Worker::Handler::IdentityMail`, `docs/audit/email-lifecycle.md`, `t/146-identity-mailer.t`, `t/154-identity-mail.t` | Delivery adapter e SMTP staging non drillati | Configurare e drillare mail su staging prima beta self-service |
| Moderation workflow | GO evidence | Report/hide/lock/workflow PASS; `FOR UPDATE` + unique `command_id`; race hide in `t/integration/postgres-concurrency.t` | Staging con utenti reali ancora da drillare | Drill moderazione su staging prima beta |
| Privacy/export/deletion | GO evidence / PARTIAL ops | Privacy rights PASS; erasure idempotency `024`; approval race in `postgres-concurrency.t` | Restore evidence con allegati ancora aperto | Attachment restore drill |
| Audit trail integrity | GO evidence | `record_hash` + `pg_advisory_xact_lock`; due append in `postgres-concurrency.t` | Nessun gap evidence residuo prioritario | Tenere verde con DSN |
| Logging e metriche | PARTIAL GO | `/metrics` token app-level, DB query stats, outbox, readiness, OS runtime evidence | Metriche process-local non aggregate, alerting esterno assente | Scrape/alert staging, aggregazione o runbook |
| Deployment Hypnotoad | PARTIAL GO | Hypnotoad smoke PASS, systemd/nginx template presenti, env file aggiunto | Non provato con systemd/nginx reali sul target | Staging deploy completo |
| Reactor backend | PARTIAL | Local macOS actual reactor `Mojo::Reactor::Poll`, documentato in `docs/ops/reactor-backend.md` | Mismatch con backend dichiarato; EV non installato localmente | Verificare reactor su Linux/FreeBSD staging |
| Config dev/staging/prod | GO | Production rifiuta secret default; prod/staging leggono profilo professionale | systemd env file deve essere creato fuori repo | Gestire `/etc/gpforum/gpforum.env` con secret manager |
| Gestione secret | PARTIAL GO | Secret default bloccato in production, nessun secret production in repo | Nessuna rotazione automatica/documentata | Definire rotazione secret e DB password |
| Documentazione operativa | PARTIAL GO | Production readiness, deployment, observability, reactor docs presenti | Checklist pubblica non ancora provata su staging | Eseguire runbook e registrare evidenza |

## Comandi eseguiti

Baseline storica (2026-06-02). I comandi sotto documentano quella review; non
sono stati ri-eseguiti in questo refresh documentale. Lo schema su `main` è
ora a 36 migrazioni (`001`–`036`).

| Comando | Esito | Output rilevante |
| --- | --- | --- |
| `carton exec script/perl-syntax-check` | PASS | Tutti i file Perl/bin/script/test syntax OK |
| `script/perltidy-check` | PASS | Nessun file non perltidy-clean |
| `script/perlcritic` | PASS | `perlcritic status=ok baseline_violations=695 new_violations=0` |
| `script/architecture-check` | PASS | Nessuna violazione boundary/cycle rilevata |
| `script/query-plan-check` | PASS | `status=ok indexes=31 offset_violations=0` |
| `git diff --check` | PASS | Nessun whitespace error |
| `carton exec script/test` | PASS | `Files=87, Tests=4680` |
| `script/coverage` | PASS | `Files=87, Tests=4680`, coverage totale 88.0% |
| Fresh migrate su DB temporaneo | PASS | 25 migrazioni all'epoca; oggi `001`–`036` |
| Upgrade 024 -> 025 su DB temporaneo | PASS | `upgrade_schema_versions_before=24`, dopo `25`, `identity_tokens_after=t` |
| `script/seed-benchmark --profile small` | PASS | 5 utenti, 3 categorie, 12 thread, 96 post |
| `script/query-budget --sync` | PASS | `synced 24 endpoint query budgets` |
| `script/query-budget --check` | PASS | `ok endpoint query budgets aligned` |
| `script/query-plan-evidence --check` | PASS | 12 endpoint ok, violazioni none |
| `carton exec bin/gpforum-platform-check --with-db` | PARTIAL | `query_budget_drift status=ok`, `os_preflight status=degraded` sul Mac locale per CPU/processi |
| `pg_dump -Fc` + `pg_restore` | PASS | Restore con 25 migrazioni all'epoca; oggi 36 versioni |
| `script/gpforum-os-preflight --json` | DEGRADED | CPU count locale 1, web process default 4 cap-to-cpu; fd limit OK |
| `script/benchmark-http --fixture --check ...` | PASS | `/categories` p95 1.637 ms, thread fixture p95 23.375 ms |
| `carton exec script/bench-outbox-dispatcher --messages 1000,10000 --workers 1,2,4` | PASS | Lost 0, duplicates 0, fino a 10k messaggi |
| `script/benchmark-http --configured --check ...` | PASS dopo fix | Thread hot path p95 7.917 ms, max DB queries 3, budget ok |
| `script/bench-hypnotoad --check --profile hot-thread --workers 2 ...` | PASS | Error rate 0, thread p95 7.295 ms, budget ok |
| `script/bench-hypnotoad-scaling --check --profile hot-thread --worker-set 2,4 ...` | PASS | Worker 2/4 ok, duplicate DB queries 0 |
| Security/failure suite mirata | PASS | 15 file, 773 test |
| Production config secret default check | PASS | `production requires GPFORUM_SESSION_SECRET` |
| Production config with secret/token | PASS | `clients=250 backlog=256 requests=1000 nofile=65536 metrics_token=set` |
| Reactor probe | PARTIAL | `Mojo::Reactor::Poll`; `EV.pm` non installato localmente |

## Blocchi alla produzione

### BLOCKER

| Blocco | Impatto | Azione richiesta |
| --- | --- | --- |
| Nessun deploy staging completo con systemd/nginx/Hypnotoad e DB target | Drill DB throwaway shippato; manca nginx/systemd end-to-end sul target | Eseguire deploy staging da commit CI verde, env file, migrate, query-budget sync, worker e health checks |
| Stress test rappresentativo non eseguito | Harness `script/stress-load` shippato (100/500/1000); manca evidenza su staging target | Eseguire load test staging con p50/p95/p99, error rate, worker distribution, DB latency |
| Backup/restore non provato su staging con attachment storage | DB dump/restore + `script/staging-drill-attachments` shippati; manca evidenza live target | Drill restore completo DB + allegati + readiness su staging |
| Mail delivery su staging non drillata | Adapter in codice; SMTP/staging non verificato | Drillare `Identity::Mailer` / worker su staging (non più “codice assente”) |

### HIGH

| Rischio | Stato | Azione richiesta |
| --- | --- | --- |
| `command_log` race concorrente | Chiuso codice + evidenza PG (`postgres-concurrency.t`) | Tenere verde con DSN |
| Bookmark/subscription check-then-insert | Chiuso codice + evidenza PG | Tenere verde con DSN |
| Report duplicati aperti | Chiuso: unique `026` + catch + evidenza PG | Tenere verde con DSN |
| Moderation actions senza command-id/row lock uniforme | Chiuso codice + evidenza hide PG; command_log su assign/release/resolve/… | Tenere verde con DSN |
| Failure mode DB down/timeout/write after commit | Chiuso fake/DB-backed + PG concurrency/idempotency/reclaim | Tenere FM + integration suite verde |
| Audit chain non serializzata | Chiuso codice + evidenza PG due append | Tenere verde con DSN |
| Privacy deletion/hold/export duplicabili | Chiuso codice + approval race PG; hold/export HTTP replay | Tenere verde; restore con allegati resta BLOCKER |

### MEDIUM

| Rischio | Stato | Azione richiesta |
| --- | --- | --- |
| Reactor backend locale Poll | Documentato | Verificare su staging Linux/FreeBSD, decidere EV/native policy |
| Metriche process-local | Accettabile per singolo nodo | Aggregare scrape o documentare dashboard per worker multipli |
| OS preflight degraded su Mac locale | Non blocca codice | Eseguire preflight su host target |
| Minion opzionale | Direct outbox disponibile e indipendente da Minion; web fail-closed se Minion è abilitato e il backend manca | Staging con `GPFORUM_MINION_ENABLED=1` solo con backend raggiungibile |
| Coverage basso in alcuni moduli operativi | Gate totale verde | Aumentare coverage quando si toccano quei moduli |

### LOW

| Rischio | Stato | Azione richiesta |
| --- | --- | --- |
| Baseline Perl::Critic storica | Gate blocca nuove violazioni | Ridurre baseline opportunisticamente |
| macOS benchmark non rappresentativo | Documentato | Non usare per capacity planning pubblico |
| Query budget richiede sync manuale | Documentato e testato | Tenere step nel runbook e in CI |

## Checklist beta privata

Prima di una beta privata self-service:

- CI verde sul commit candidato.
- Fresh install e upgrade applicati a staging (attraverso migrazione `036`).
- `script/query-budget --sync` e `--check` verdi su staging.
- `/health/live`, `/health/ready`, `/metrics` con token verdi su staging.
- Mail delivery configurato e drillato per reset password e cambio email.
- Backup/restore DB + attachment storage provato.
- Failure suite FM-001–FM-010 verde; integration PG
  (`postgres-concurrency` / `postgres-idempotency` / `postgres-outbox-reclaim`)
  verde con DSN, o runbook di supporto manuale accettato.
- Moderation base provata con utenti reali e ruoli seeded.
- Dead-letter outbox osservata con un failure controllato.
- Stress test almeno 100 utenti concorrenti su `/categories`, thread view,
  search e reply.

## Checklist produzione pubblica

Prima del go-live pubblico:

- Tutti i BLOCKER chiusi.
- Tutti gli HIGH chiusi o formalmente accettati con mitigazione e rollback.
- Stress 100/500/1000 utenti su staging con p50/p95/p99, error rate, DB latency
  e worker distribution.
- Integration PG già in tree; ripetere su staging target con DSN reale.
- Backup/restore con RPO/RTO misurati (inclusi attachment blob).
- Rollback/forward-fix provato con lo stesso systemd/nginx shape.
- `/metrics` protetto da token app-level e allowlist/private network.
- Secret gestiti fuori repo con rotazione documentata.
- Query-plan evidence su dataset rappresentativo medium/hot-thread.
- Worker outbox retry, reclaim e dead-letter provati in staging.
- Reactor backend e OS preflight verificati su host target.

## Raccomandazione finale

Non aggiungere funzionalità di prodotto. I gap HIGH di concorrenza/idempotency
PG e reclaim outbox sono evidence-closed in tree. Il prossimo lavoro chiude i
BLOCKER operativi residui: stress 100/500/1000, attachment restore + deploy
nginx/systemd, SMTP staging. GPForum resta locale-ready; beta privata
self-service e produzione pubblica richiedono ancora quelle prove.
