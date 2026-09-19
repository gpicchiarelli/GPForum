# Audit email lifecycle

Data: 2026-09-19.

Area completata in questo incremento: reset password, cambio password, cambio
email e verifica registrazione, con consegna mail tramite
`Identity::Mailer` e `Email::Sender`.

## Rischio mitigato

Prima dell'incremento il repository aveva login, logout, sessioni revocabili,
hash password Argon2id e audit identity, ma non aveva un lifecycle verificabile
per reset password o cambio email. Il rischio era `high`: recupero account o
cambio email non implementabili senza token raw improvvisati, assenza di
scadenza/uso singolo, replay possibile e audit incompleto. La consegna restava
scollegata: i token venivano emessi e poi scartati.

## Patch applicata

- `identity_tokens` persiste token hashati, tipo, scadenza, `used_at`, email
  pendente e metadata.
- `Identity::AccountStore` generates token raw only at the service boundary and
  saves only `token_hash`; `Identity::Store` delegates those commands.
- `reset_password` consuma il token in transazione, blocca la riga con
  `FOR UPDATE` quando il DBH è disponibile, marca `used_at`, ruota la credential
  password e revoca le sessioni attive.
- `change_password` verifica la password corrente prima di ruotare credential e
  audit.
- `request_email_change` crea un token `email_change` per la nuova email
  normalizzata.
- `confirm_email_change` consuma il token e aggiorna `email_normalized` più
  `email_verified_at`.
- La registrazione emette un token `email_verification`. `confirm_email_verification`
  attiva l'account (`status=active`) e marca `email_verified_at`.
- `Identity::AuthStore` rifiuta il login dei pending (`unverified`) e non apre
  sessione. Gli admin bootstrap già `active` non richiedono `email_verified_at`.
- `Identity::Workflow` consegna reset, cambio email e verifica tramite
  `Identity::Mailer` dopo il commit della transazione, poi rimuove il token raw
  dal risultato. I token raw non vengono loggati.
- Configurazione da `GPForum::Config` / `GPFORUM_MAIL_*`: transport `test` in
  development/test, `sendmail` in staging/production, SMTP opzionale.
  `Email::Address::XS` 1.05 è pin runtime per `Email::Sender::Simple`.
- Le POST HTTP sono protette da CSRF plaintext (`IdentityAccess`) e rate-limit
  applicativo.
- Gli eventi sensibili sono registrati in audit con hash di identificatore,
  indirizzo o email, mai token raw.

## Evidenza test

- `t/08-identity-store.t`: token hashato, scadenza, lock SQL, uso singolo,
  rotazione credential, revoca sessioni, audit, cambio email confermato e replay
  respinto.
- `t/110-identity-account-store.t`: comandi password/email/verifica sull'account
  store con collaboratori iniettati, senza `Crypt::URandom`.
- `t/111-identity-auth-store.t`: login pending rifiutato senza sessione.
- `t/06-identity-web.t`: CSRF, rate-limit reset, link forgot-password, route
  reset, route cambio password/email e conferma email.
- `t/146-identity-mailer.t`: transport `Test`, link nel body, nessun token nei
  log.
- `t/147-identity-email-verification.t`: consegna workflow e route verify CSRF.
- `t/05-database.t`: schema DBIC, migration `025`, unique token hash e indici.

## Limiti residui

- La consegna è sincrona sul boundary del workflow: non passa dall'outbox. Se
  l'invio fallisce dopo l'emissione del token, l'errore è loggato e la
  richiesta HTTP resta non enumerativa.
- Manca test concorrente PostgreSQL reale con due conferme simultanee dello
  stesso token. Il contratto SQL `FOR UPDATE` è testato, ma non lo scheduling DB.
- Reset/cambio email non hanno ancora command idempotency key HTTP dedicata; il
  vincolo `identity_tokens_hash_key` e `used_at` proteggono il replay del token,
  non il replay identico della richiesta di emissione.

## Comandi minimi

```sh
carton exec prove -lr t/05-database.t t/06-identity-web.t t/08-identity-store.t \
  t/146-identity-mailer.t t/147-identity-email-verification.t
script/perltidy-check
script/perlcritic
```
