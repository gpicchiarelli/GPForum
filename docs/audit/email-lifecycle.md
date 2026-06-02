# Audit email lifecycle

Data: 2026-06-02.

Area completata in questo incremento: reset password, cambio password e cambio
email con conferma tramite token monouso.

## Rischio mitigato

Prima dell'incremento il repository aveva login, logout, sessioni revocabili,
hash password Argon2id e audit identity, ma non aveva un lifecycle verificabile
per reset password o cambio email. Il rischio era `high`: recupero account o
cambio email non implementabili senza token raw improvvisati, assenza di
scadenza/uso singolo, replay possibile e audit incompleto.

## Patch applicata

- `identity_tokens` persiste token hashati, tipo, scadenza, `used_at`, email
  pendente e metadata.
- `Identity::Store` genera token raw solo al boundary di servizio e salva solo
  `token_hash`.
- `reset_password` consuma il token in transazione, blocca la riga con
  `FOR UPDATE` quando il DBH è disponibile, marca `used_at`, ruota la credential
  password e revoca le sessioni attive.
- `change_password` verifica la password corrente prima di ruotare credential e
  audit.
- `request_email_change` crea un token `email_change` per la nuova email
  normalizzata.
- `confirm_email_change` consuma il token e aggiorna `email_normalized` più
  `email_verified_at`.
- Le POST HTTP sono protette da CSRF e rate-limit applicativo.
- Gli eventi sensibili sono registrati in audit con hash di identificatore,
  indirizzo o email, mai token raw.

## Evidenza test

- `t/08-identity-store.t`: token hashato, scadenza, lock SQL, uso singolo,
  rotazione credential, revoca sessioni, audit, cambio email confermato e replay
  respinto.
- `t/06-identity-web.t`: CSRF, rate-limit reset, route reset, route cambio
  password/email e conferma email.
- `t/05-database.t`: schema DBIC, migration `025`, unique token hash e indici.

## Limiti residui

- La consegna email non è ancora collegata a un mailer applicativo configurabile:
  il servizio ritorna il token raw al boundary, ma controller e template non lo
  espongono. Per beta privata serve aggiungere un delivery adapter configurato e
  testato.
- Manca test concorrente PostgreSQL reale con due conferme simultanee dello
  stesso token. Il contratto SQL `FOR UPDATE` è testato, ma non lo scheduling DB.
- Reset/cambio email non hanno ancora command idempotency key HTTP dedicata; il
  vincolo `identity_tokens_hash_key` e `used_at` proteggono il replay del token,
  non il replay identico della richiesta di emissione.

## Comandi minimi

```sh
carton exec prove -lr t/05-database.t t/06-identity-web.t t/08-identity-store.t
script/perltidy-check
script/perlcritic
```
