# Reactor backend

Data: 2026-06-02.

Questo documento spiega l'anomalia osservata:

```text
declared_event_backend=epoll
actual_reactor=Mojo::Reactor::Poll
```

## Diagnosi

`declared_event_backend` descrive la postura OS desiderata o dichiarata dal
profilo runtime. `actual_reactor` è invece la classe realmente usata da
Mojolicious in quel processo Perl.

Su macOS è normale vedere `Mojo::Reactor::Poll`: `epoll` è Linux-specifico e non
può essere il backend reale. Su Linux, `epoll` non appare come reactor nativo
Mojolicious a meno che l'ambiente abbia dipendenze/event loop compatibili e
Mojolicious scelga un reactor diverso da Poll. Per questo il mismatch deve
essere trattato come segnale diagnostico, non come errore universale.

## Stato repository

Il repository ha già evidenza runtime:

- `lib/GPForum/OS/RuntimeEvidence.pm` registra reactor dichiarato, reactor
  atteso, reactor reale e raccomandazione;
- `docs/OS_RUNTIME_EVIDENCE.md` documenta il mismatch locale;
- `t/58-os-runtime-evidence.t` copre profili OS e fallback;
- `t/57-hypnotoad-benchmark.t` verifica che il report benchmark includa
  `actual_reactor`.

## Regola operativa

| Ambiente | Comportamento atteso | Gate |
| --- | --- | --- |
| macOS dev | `Mojo::Reactor::Poll` accettabile | warning diagnostico |
| FreeBSD dev/staging | fallback accettabile se documentato | warning diagnostico |
| Linux production | mismatch da investigare | fail solo in preflight strict |
| CI generica | non assumere epoll | test portabile, no falso fail |

## Patch proposta

Non forzare un nuovo reactor come dipendenza obbligatoria. Prima rendere il
messaggio più chiaro:

- distinguere `declared_event_backend` da `actual_reactor`;
- indicare OS rilevato;
- indicare se il mismatch è atteso su OS non Linux;
- in `--strict`, fallire solo quando il profilo dichiara Linux/epoll e il
  target production richiede esplicitamente native reactor.

## Test richiesti

1. macOS/fallback: mismatch epoll/Poll produce warning, non fail.
2. Linux strict: profilo production con native backend richiesto e Poll reale
   produce fail diagnostico.
3. CI portability: test non assume epoll quando `uname` non è Linux.
4. Benchmark report: `actual_reactor` e raccomandazione restano visibili in
   output text e JSON.

## Deploy

In produzione non usare il reactor come unica prova di readiness. Verificare
insieme:

- `/health/ready`;
- query plan evidence;
- benchmark Hypnotoad con worker reali;
- file descriptor e backlog;
- p95/p99 request latency;
- outbox pending/failed/dead-letter.
