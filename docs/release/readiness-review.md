# GPForum release-readiness review

Data: 2026-06-02.

Scopo: valutare GPForum dopo le patch di stabilizzazione senza introdurre nuove
funzionalità. Questa review distingue tre livelli: uso locale personale, beta
privata e produzione pubblica.

## Release verdict

| Target | Verdetto | Motivazione tecnica |
| --- | --- | --- |
| LOCAL READY | sì | Suite completa, coverage, migrazioni fresh/upgrade, backup/restore locale, query budget, benchmark smoke/stress locali e security/failure suite sono verdi. |
| PRIVATE BETA READY | no | La codebase è vicina, ma per utenti reali self-service mancano mail delivery per reset/cambio email, staging drill e chiusura dei principali rischi HIGH di idempotenza/failure mode. Può reggere solo una alpha privata operator-assisted. |
| PUBLIC PRODUCTION READY | no | Mancano staging rappresentativo, stress test 100/500/1000 utenti, failure mode distruttivi DB-backed, audit chain serializzata, idempotenza concorrente completa e runbook di rollback provato sul target. |

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
| Test suite completa | GO | `carton exec script/test`: 87 file, 4680 test, PASS | Nessuno bloccante locale | Mantenere in CI |
| Migrazioni fresh install | GO | DB temporaneo Postgres.app: 25 migrazioni applicate, `identity_tokens` presente, secondo apply senza pending | Non ancora su staging target | Ripetere su staging PostgreSQL uguale alla produzione |
| Migrazioni upgrade | GO locale | DB temporaneo 024 -> 025: prima 24 versioni, poi `025 identity lifecycle tokens`, dopo 25 versioni | Solo percorso 024->025 provato localmente | Ripetere da snapshot staging/restored |
| Rollback migrazioni | NO-GO produzione | Documentata strategia forward-fix in `docs/PRODUCTION_READINESS.md` | Rollback non provato con sistema/nginx/systemd reale | Rehearsal forward-fix e restore drill su staging |
| Perl::Critic | GO | `script/perlcritic`: `new_violations=0` | Restano baseline note, non nuove | Non allargare baseline senza review |
| Perltidy | GO | `script/perltidy-check`: PASS | Nessuno | Mantenere gate |
| Coverage | GO | `script/coverage`: PASS, totale 88.0% | Alcuni moduli operativi hanno coverage basso, ma gate passa | Aumentare coverage su realtime/controller solo se toccati |
| Benchmark smoke | GO | Fixture e configured benchmark verdi | Numeri locali, non staging | Ripetere con dataset rappresentativo |
| Benchmark stress | PARTIAL | Hypnotoad scaling hot-thread 2/4 worker PASS; outbox 1k/10k messaggi PASS | Non prova 100/500/1000 utenti né multicore reale | Stress esterno con 100/500/1000 utenti su staging |
| Query budget | GO | `script/query-budget --sync`, `--check`: PASS; route thread max 3 query, budget ok | Catalog deve essere sincronizzato in deploy | Eseguire sync/check dopo ogni migration deploy |
| Query plan | GO | `script/query-plan-check`: `indexes=31`, `offset_violations=0`; `query-plan-evidence` PASS su small | Dataset locale piccolo | Medium/hot-thread staging evidence |
| Security audit | PARTIAL GO | Security suite mirata: 15 file, 773 test, PASS | Bot/device anomaly e alcuni failure write DB-down non coperti | Estendere failure/security tests prima beta |
| Failure mode tests | NO-GO produzione | Outbox retry/dead-letter, forum rollback, readiness, realtime degradato coperti | DB down/timeout write, errore dopo commit, worker crash reale non coperti end-to-end | Aggiungere failure tests DB-backed |
| Backup/restore | GO locale | `pg_dump -Fc` e `pg_restore`: 25 schema_versions, 5 utenti, 12 thread ripristinati | Non provato con attachment storage né staging RPO/RTO | Restore drill staging con allegati |
| Session security | GO | Sessioni server-side, revoca, scadenza, cookie flags e CSRF coperti da suite security | Revoca globale sessioni/device anomaly non avanzata | Accettabile per locale, estendere per beta |
| Rate limiting | GO | PostgreSQL limiter, fallback telemetry e blocked audit coperti | Fallback local memory non cluster-wide | In beta usare PostgreSQL store e monitorare fallback |
| Email lifecycle | PARTIAL | Reset password, cambio password, cambio email, token monouso, scadenza, CSRF, rate-limit, audit: PASS | Mail delivery non cablata, token non consegnabili agli utenti | Integrare mail adapter configurabile prima beta self-service |
| Moderation workflow | GO | Report, hide/restore, lock/unlock, assign/release/resolve/reverse, suspension e web tests PASS; queue e reverse replay da `command_log` | Evidenza PostgreSQL concorrente assente | Lock row e unique `command_id` restano sullo store hide/restore |
| Privacy/export/deletion | PARTIAL GO | Privacy rights e web tests PASS; erasure job idempotency migration 024 | Concorrenza reale su approval/holds non provata | Test PostgreSQL concorrenti e restore evidence |
| Audit trail integrity | PARTIAL | `record_hash` canonico e `pg_advisory_xact_lock` sul lookup | Evidenza PostgreSQL concorrente ancora assente | Due append concorrenti su staging |
| Logging e metriche | PARTIAL GO | `/metrics` token app-level, DB query stats, outbox, readiness, OS runtime evidence | Metriche process-local non aggregate, alerting esterno assente | Scrape/alert staging, aggregazione o runbook |
| Deployment Hypnotoad | PARTIAL GO | Hypnotoad smoke PASS, systemd/nginx template presenti, env file aggiunto | Non provato con systemd/nginx reali sul target | Staging deploy completo |
| Reactor backend | PARTIAL | Local macOS actual reactor `Mojo::Reactor::Poll`, documentato in `docs/ops/reactor-backend.md` | Mismatch con backend dichiarato; EV non installato localmente | Verificare reactor su Linux/FreeBSD staging |
| Config dev/staging/prod | GO | Production rifiuta secret default; prod/staging leggono profilo professionale | systemd env file deve essere creato fuori repo | Gestire `/etc/gpforum/gpforum.env` con secret manager |
| Gestione secret | PARTIAL GO | Secret default bloccato in production, nessun secret production in repo | Nessuna rotazione automatica/documentata | Definire rotazione secret e DB password |
| Documentazione operativa | PARTIAL GO | Production readiness, deployment, observability, reactor docs presenti e aggiornati | Checklist pubblica non ancora provata su staging | Eseguire runbook e registrare evidenza |

## Comandi eseguiti

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
| Fresh migrate su DB temporaneo | PASS | 25 migrazioni, `identity_tokens_present=t`, secondo apply `0` righe |
| Upgrade 024 -> 025 su DB temporaneo | PASS | `upgrade_schema_versions_before=24`, dopo `25`, `identity_tokens_after=t` |
| `script/seed-benchmark --profile small` | PASS | 5 utenti, 3 categorie, 12 thread, 96 post |
| `script/query-budget --sync` | PASS | `synced 24 endpoint query budgets` |
| `script/query-budget --check` | PASS | `ok endpoint query budgets aligned` |
| `script/query-plan-evidence --check` | PASS | 12 endpoint ok, violazioni none |
| `carton exec bin/gpforum-platform-check --with-db` | PARTIAL | `query_budget_drift status=ok`, `os_preflight status=degraded` sul Mac locale per CPU/processi |
| `pg_dump -Fc` + `pg_restore` | PASS | Restore con 25 migrazioni, 5 utenti, 12 thread |
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
| Nessun deploy staging completo con systemd/nginx/Hypnotoad e DB target | Non esiste evidenza che il runbook reale funzioni sul target | Eseguire deploy staging da commit CI verde, includendo env file, migrate, query-budget sync, worker e health checks |
| Stress test rappresentativo non eseguito | Local hot-thread smoke non prova 100/500/1000 utenti | Eseguire load test staging con p50/p95/p99, error rate, worker distribution, DB latency |
| Backup/restore non provato su staging con attachment storage | RPO/RTO non dimostrati | Drill restore completo DB + allegati + readiness |
| Mail delivery assente per email lifecycle self-service | Utenti beta/pubblici non ricevono reset/cambio email | Aggiungere e testare delivery adapter configurabile o definire supporto manuale per alpha soltanto |

### HIGH

| Rischio | Stato | Azione richiesta |
| --- | --- | --- |
| `command_log` race concorrente | Chiuso in codice (catch unique → replay) | Evidenza PostgreSQL con due connessioni |
| Bookmark/subscription check-then-insert | Chiuso in codice (unique + restore) | Evidenza PostgreSQL concorrente |
| Report duplicati aperti | Chiuso: unique parziale `026` + catch | Evidenza PostgreSQL concorrente |
| Moderation actions senza command-id/row lock uniforme | Chiuso in codice (`FOR UPDATE` + unique `command_id` su hide/restore/lock/unlock; `command_log` su assign/release/resolve/reverse/suspend/revoke) | Evidenza PostgreSQL concorrente |
| Failure mode DB down/timeout/write after commit | Parziale | Test end-to-end su write principali |
| Audit chain non serializzata | Chiuso in codice (`pg_advisory_xact_lock`) | Evidenza PostgreSQL concorrente |
| Privacy deletion/hold/export duplicabili | Chiuso in codice (`command_id` HTTP + replay richiesta/hold/export aperti) | Unique index e evidenza PostgreSQL concorrente |

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
- Fresh install e upgrade applicati a staging.
- `script/query-budget --sync` e `--check` verdi su staging.
- `/health/live`, `/health/ready`, `/metrics` con token verdi su staging.
- Mail delivery configurato per reset password e cambio email.
- Backup/restore DB + attachment storage provato.
- Failure test DB unavailable sulle write principali aggiunti o runbook di
  supporto manuale accettato.
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
- Test PostgreSQL concorrenti per `command_log`, report, bookmark,
  subscription, moderation e audit chain.
- Backup/restore con RPO/RTO misurati.
- Rollback/forward-fix provato con lo stesso systemd/nginx shape.
- `/metrics` protetto da token app-level e allowlist/private network.
- Secret gestiti fuori repo con rotazione documentata.
- Query-plan evidence su dataset rappresentativo medium/hot-thread.
- Worker outbox retry, reclaim e dead-letter provati in staging.
- Reactor backend e OS preflight verificati su host target.

## Raccomandazione finale

Non aggiungere funzionalità. Il prossimo lavoro deve chiudere i BLOCKER/HIGH di
correttezza, idempotenza, failure mode e staging evidence. GPForum è una
codebase locale verificabile e seriamente strutturata, ma la produzione pubblica
richiede ancora prove operative e concorrenza reale su PostgreSQL.
