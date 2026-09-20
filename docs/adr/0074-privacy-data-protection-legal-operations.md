# ADR 0074: Privacy, Data Protection and Legal Operations

## Status

Accepted. Converted on 2026-09-19 from `prompt/26.txt` ("GPForum - Privacy,
Data Protection & Legal Operations Constitution"); this ADR replaces the
prompt as the binding source.

## Context

GPForum stores account identifiers, credentials, session and security
metadata, authored content, attachments and moderation records. Privacy,
data protection, user data rights, legal compliance, consent, retention,
export, deletion and policy operations need mandatory standards so that user
data is minimized, access-controlled and deletable or anonymizable on a
defined basis. The rules govern the privacy, identity, forum, attachment,
notification, moderation, search and audit bounded contexts.

## Decision

### Cross-ADR alignment

- ADR 0100 (domain integrity): privacy and data-rights workflows MUST not
  leak private, moderated, hidden, deleted, quarantined or restricted content
  through search, feeds, metadata, previews, notifications, projections,
  caches, exports, plugin hooks or realtime events.

### Privacy philosophy

GPForum MUST treat user data as sensitive operational material.

The platform MUST prioritize: data minimization; explicit purpose; access
control; auditability; retention discipline; user rights; breach readiness.

The platform MUST avoid: unnecessary personal data collection; indefinite
retention without reason; hidden tracking; leaking moderation/security data;
storing secrets in logs; exposing private data through search or cache.

### Personal data categories

- The platform SHOULD classify: account identifiers; email addresses;
  authentication data; session metadata; IP-derived security metadata;
  user-authored content; attachments; moderation records; notification
  preferences; audit logs.
- Each category MUST have: purpose; retention expectation; access rules;
  deletion or anonymization policy.

### User rights

- Where legally applicable, GPForum SHOULD support: access request; data
  export; correction; account deletion; anonymization; objection to optional
  processing; consent withdrawal.
- User rights workflows MUST be: authenticated; audited; rate-limited;
  abuse-aware.

### Account deletion

- Account deletion MUST distinguish between: account access removal; profile
  anonymization; content retention for conversation integrity; legal
  deletion requirements; moderation/audit retention.
- Deleting an account MUST NOT automatically destroy discussion coherence
  unless policy requires it.
- User-authored content MAY be anonymized instead of removed where lawful and
  disclosed.

### Data export

- Data export SHOULD include: profile data; authored posts; uploaded
  attachment references where allowed; notification preferences;
  subscription data; account security events safe to disclose.
- Exports MUST NOT include: other users' private data; internal moderation
  notes not legally required; secret hashes; infrastructure details;
  privileged audit context.

### Consent and cookies

- Essential cookies MAY be required for: session; CSRF protection; security;
  preferences.
- Optional cookies or tracking MUST require appropriate consent where
  legally applicable.
- Consent records SHOULD be: versioned; timestamped; revocable; auditable.

### Retention

- Retention policies MUST cover: sessions; audit logs; security logs; deleted
  content; attachments; notifications; analytics; backups.
- Retention enforcement SHOULD be automated through scheduled jobs.
- Retention jobs MUST be observable and auditable.

### Moderation and privacy

- Moderation data is sensitive.
- Moderation records MUST be visible only to authorized staff.
- Reports MUST protect reporter identity from unauthorized users.
- Staff access to sensitive moderation records SHOULD be logged.

### Search and privacy

- Search indexing MUST respect: visibility; deletion; quarantine;
  permissions; privacy restrictions.
- Private or restricted content MUST NOT leak through snippets,
  autocomplete, counts or cached results.

### Breach readiness

- The platform MUST support: security incident identification; affected
  data classification; audit review; credential/session revocation;
  operational reporting; legal notification workflows where required.
- Incident response MUST have a runbook (ADR 0075).

### Policy versioning

- Terms, privacy policy and community guidelines SHOULD be versioned.
- Policy acceptance SHOULD record: user id; policy version; `accepted_at`;
  source.
- Policy changes that affect user rights SHOULD be communicated clearly.

## Consequences

- Every personal data category carries an explicit purpose, retention,
  access and deletion/anonymization rule, so new tables or fields that hold
  personal data must declare them.
- Account deletion is a multi-part workflow rather than a row delete:
  conversation coherence and audit retention are preserved while access and
  identity are removed or anonymized.
- Retention becomes scheduled, observable and audited work, adding worker
  and monitoring load.
- Search, caches, exports and realtime paths must all apply the same
  visibility and deletion filters, which constrains projection design
  (ADR 0090).

## Alignment

- ADRs: 0100 (cross-alignment), 0053 (security), 0062 and 0090 (search),
  0075 (incident runbook), 0080 (policy versions), 0081 (export); 0013
  (privacy workflow boundary), 0023 (privacy erasure record), 0029 (privacy
  completion replay), 0032 (privacy event), 0033 (retention hold event),
  0045 (privacy access).
- Code: `lib/GPForum/Service/Privacy/`, `lib/GPForum/Controller/Privacy.pm`,
  `lib/GPForum/Controller/Privacy/`, `lib/GPForum/Web/PrivacyAccess.pm`.
- Migrations: `migrations/024_privacy_erasure_job_idempotency.sql`.
- Tests: `t/29-privacy-rights.t`, `t/62-privacy-web.t`,
  `t/100-privacy-controllers.t`, `t/101-privacy-workflow.t`,
  `t/119-privacy-erasure.t`, `t/125-privacy-completion.t`,
  `t/128-privacy-event.t`, `t/136-web-privacy-access.t`.
- Docs: `docs/architecture/privacy-workflow.md`.
