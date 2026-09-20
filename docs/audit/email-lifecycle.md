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
  password e revoca le sessioni attive. Un reset della stessa secret già in
  uso consuma il token e revoca le sessioni, ma non ruota la credential.
- `change_password` verifica la password corrente prima di ruotare credential e
  audit. POST `/settings/password` mintano e richiedono `command_id`; lo stesso
  comando replay da `command_log` senza una seconda rotazione, anche quando la
  password corrente nel retry è già quella nuova. Una seconda write store della
  stessa secret non ruota la credential. L'hash in `command_log`
  contiene solo `user_id`, mai le password.
- `request_email_change` crea un token `email_change` per la nuova email
  normalizzata. Una request dell'email già verificata del membro non emette
  token né mail.
- `confirm_email_change` consuma il token e aggiorna `email_normalized` più
  `email_verified_at`. Un secondo confirm della stessa email già verificata
  non rista il timestamp.
- La registrazione emette un token `email_verification`. `confirm_email_verification`
  attiva l'account (`status=active`) e marca `email_verified_at`. Un secondo
  confirm su un account già attivo e già verificato non rista il timestamp.
- `Identity::AuthStore` rifiuta il login dei pending (`unverified`) e non apre
  sessione. Gli admin bootstrap già `active` non richiedono `email_verified_at`.
- `Identity::AccountStore` queues reset, email-change, and verification mail
  on the outbox in the same transaction as token issuance. EventLog keeps
  `kind` and `token_id`; the raw token lives only on the outbox `mail`
  payload. `Identity::Workflow` strips the raw token from the HTTP result.
  I token raw non vengono loggati.
- Configurazione da `GPForum::Config` / `GPFORUM_MAIL_*`: transport `test` in
  development/test, `sendmail` in staging/production, SMTP opzionale.
  `Email::Address::XS` 1.05 è pin runtime per `Email::Sender::Simple`.
- Le POST HTTP sono protette da CSRF plaintext (`IdentityAccess`) e rate-limit
  applicativo. `register`, `login`, `logout`, `change_password`, `request_password_reset`,
  `reset_password`, `request_email_change`, `confirm_email_change`,
  `request_email_verification` e `verify_email` mintano e richiedono
  `command_id`; lo stesso comando replay da `command_log` senza un secondo
  account pending, una seconda sessione, una seconda revoca, una seconda
  rotazione password, un secondo token o un secondo consume. L'hash di
  registrazione in `command_log` contiene email e username, mai la password.
  L'hash di login contiene solo l'identificatore. L'hash di logout contiene
  `session_id` e `user_id`. L'hash di cambio password contiene solo
  `user_id`. L'hash di consume contiene il token, mai una nuova password.
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
  reset, route cambio password/email e conferma email. Le form di
  registrazione, login, logout, cambio password, emissione e consume mintano `command_id`.
- `t/103-identity-workflow.t`: `command_id` obbligatorio; replay e conflict
  del command log per registrazione, login, logout, cambio password, emissione token e consume.
- `t/152-write-unavailable.t`: command-log down su registrazione, login,
  logout, cambio password, emissione e consume torna 503 senza leakage.
- `t/153-lost-response-retry.t`: retry HTTP con lo stesso `command_id` non
  crea un secondo account pending, non apre una seconda sessione, non
  revoca due volte la sessione, non ruota due volte la password, non emette
  un secondo token e non consuma due volte il token.
- `t/146-identity-mailer.t`: transport `Test`, link nel body, nessun token nei
  log.
- `t/147-identity-email-verification.t`: workflow strips tokens; verify CSRF.
- `t/154-identity-mail.t`: EventLog omits the raw token; outbox and handler
  deliver it. `t/150-outbox-handler-idempotency.t` proves a send-before-ack
  crash resends from the outbox payload.
- `t/05-database.t`: schema DBIC, migration `025`, unique token hash e indici.

## Limiti residui

- Identity mail resta at-least-once: un retry dopo send e prima di
  `mark_done` reinvia. EventLog non contiene il token raw, quindi il
  retry legge solo la payload outbox.
- Manca test concorrente PostgreSQL reale con due conferme simultanee dello
  stesso token. Il contratto SQL `FOR UPDATE` è testato, ma non lo scheduling DB.
- Un `command_id` diverso sulla stessa emissione ruota il token unused
  esistente per `(user_id, token_type)` invece di inserirne un secondo.
  `identity_tokens_hash_key` e `used_at` restano la protezione sul consume.
  Username e email restano unique: una seconda registrazione con `command_id`
  diverso non crea un secondo account pending. Una unique race in insert
  torna gli stessi errori duplicate senza una seconda riga.

## Comandi minimi

```sh
carton exec prove -lr t/05-database.t t/06-identity-web.t t/08-identity-store.t \
  t/103-identity-workflow.t t/146-identity-mailer.t \
  t/147-identity-email-verification.t t/152-write-unavailable.t \
  t/153-lost-response-retry.t
script/perltidy-check
script/perlcritic
```
