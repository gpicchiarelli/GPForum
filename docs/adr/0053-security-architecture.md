# ADR 0053: Security Architecture Constitution

## Status

Accepted. Converted on 2026-09-19 from `prompt/5.txt` ("GPForum — Security
Architecture Constitution"); this ADR replaces the prompt as the binding
source.

## Context

Security is foundational and non-optional for GPForum (ADR 0049). This ADR
defines the mandatory security architecture, trust model, authentication
strategy, authorization framework, audit discipline, browser security
requirements, input validation standards, operational hardening rules, and
defensive engineering philosophy. All future architecture, code,
infrastructure, APIs, themes, plugins, and operational procedures MUST comply
with it; it governs identity, sessions, authorization, moderation, uploads,
realtime, APIs, administration, and operations.

## Decision

### Domain Integrity Alignment (ADR 0100)

- Security-sensitive workflows MUST preserve: domain integrity; explicit
  authorization; moderation safety; immutable audit records; anti-leak
  guarantees; replay-safe event semantics.

### Security Philosophy

- GPForum MUST assume: hostile input; malicious users; compromised clients;
  automated attacks; distributed abuse; supply-chain threats; credential
  theft attempts.
- Security MUST remain: proactive; layered; explicit; observable; auditable;
  defense-in-depth oriented.
- The platform MUST prioritize: minimizing attack surface; deterministic
  behavior; strict validation; operational visibility; least privilege.

### Threat Model

- The platform MUST explicitly defend against: XSS; CSRF; SSRF; SQL
  injection; websocket abuse; credential stuffing; brute force attacks;
  privilege escalation; session hijacking; cache poisoning; path traversal;
  unsafe uploads; deserialization attacks; event replay abuse; API abuse;
  distributed spam; moderation bypass attempts.
- The system MUST assume: persistent hostile traffic; automated scraping;
  bot-driven attacks.

### Authentication Philosophy

- Authentication MUST support: strong password hashing; passwordless
  authentication; multi-factor authentication; session revocation;
  distributed deployments.
- Mandatory password hashing: Argon2id.
- Passwords MUST NEVER: be reversibly encrypted; be logged; be recoverable.

### WebAuthn

- The platform SHOULD support WebAuthn/passkeys.
- WebAuthn support MUST remain: first-class; standards-compliant;
  security-focused.

### Multi-Factor Authentication

- Mandatory MFA support: TOTP; WebAuthn-based MFA.
- Administrative accounts SHOULD require MFA.

### Session Security

- Sessions MUST: support revocation; support expiration; support rotation;
  remain distributed-safe.
- Sessions MUST: avoid local filesystem persistence; avoid predictable
  identifiers.
- Cookies MUST use: Secure; HttpOnly; SameSite protections.

### Authorization Philosophy

- Authorization MUST remain: explicit; centralized; auditable;
  deny-by-default.
- The platform MUST implement RBAC + ABAC hybrid authorization.
- Authorization MUST support: scoped moderation; resource ownership;
  temporary permissions; contextual restrictions.

### Permission Model

- The permission system MUST support: roles; capabilities; resource-scoped
  permissions; contextual policies; moderation scopes.
- The platform MUST avoid: simplistic boolean admin flags; hardcoded
  authorization shortcuts.

### Input Validation

- All external input MUST be treated as hostile.
- Validation MUST occur before: persistence; authorization-sensitive
  actions; event creation; rendering; asynchronous processing.
- Mandatory validation targets: HTTP payloads; websocket payloads; uploads;
  headers; JSON structures; search queries; markdown content.

### Output Encoding

- All rendered output MUST: remain context-aware; use proper escaping; avoid
  unsafe interpolation.
- User-generated content MUST NEVER bypass sanitization.

### HTML Sanitization

- The platform MUST implement strict HTML sanitization.
- The preferred content model is: restricted markdown; sanitized rendering;
  allowlist-based formatting.
- User-provided JavaScript is prohibited.
- Unsafe embedded content is prohibited.

### Browser Security

- Mandatory browser protections: CSP; HSTS; X-Frame-Options;
  Referrer-Policy; X-Content-Type-Options.
- The platform MUST minimize: inline JavaScript; unsafe script execution;
  remote third-party execution.

### CSP Philosophy

- The Content Security Policy MUST remain: restrictive; explicit;
  nonce-aware where required.
- Unsafe CSP configurations are prohibited. Prohibited examples:
  `unsafe-inline`; unrestricted third-party scripts.

### CSRF Protection

- All state-changing operations MUST require CSRF protection or use
  explicitly safe token mechanisms.
- Session-authenticated requests MUST remain CSRF-resistant.

### API Security

- APIs MUST: authenticate explicitly; authorize explicitly; validate
  payloads; rate limit abusive traffic.
- Public APIs MUST assume hostile automation.

### Websocket Security

- Websocket endpoints MUST: authenticate connections; validate payloads;
  authorize actions; rate limit events.
- Realtime systems MUST assume: hostile payload injection attempts; flooding
  attacks; replay attempts.

### Rate Limiting

- The platform MUST support: IP rate limiting; account rate limiting;
  endpoint-specific limits; abuse throttling.
- Rate limits SHOULD apply to: login; registration; posting; websocket
  events; API usage; search.

### Abuse Prevention

- The architecture MUST support: spam mitigation; bot mitigation;
  moderation automation; abuse scoring.
- The platform SHOULD support: behavioral heuristics; trust levels;
  progressive restrictions.

### Upload Security

- Uploads MUST: remain isolated; support MIME validation; support antivirus
  scanning; support extension validation; support size limits.
- User uploads MUST NOT execute server-side.

### Object Storage Security

- Attachments SHOULD use: object storage; immutable asset delivery; signed
  URLs where appropriate.
- The platform MUST avoid: executable uploads; unsafe content serving.

### Audit Logging

- The platform MUST implement append-only audit logging.
- Security-sensitive operations MUST generate audit events. Examples: login
  attempts; MFA changes; permission changes; moderation actions; token
  revocations; administrative operations.
- Audit logs MUST remain: immutable; queryable; timestamped; attributable.

### Secret Management

- Secrets MUST: remain externalized; avoid repository storage; avoid
  plaintext logging. Examples: database credentials; signing keys; API
  secrets; encryption material.
- Secrets rotation MUST remain possible.

### Cryptography Philosophy

- The platform MUST use: modern cryptography; maintained libraries; explicit
  algorithms.
- Custom cryptography is prohibited.
- Weak algorithms are prohibited.

### Event Security

- Events MUST: remain attributable; remain immutable; support replay
  protection where required.
- Security-sensitive workflows MUST remain auditable.

### Administrative Security

- Administrative actions MUST: require explicit authorization; remain fully
  auditable; support attribution; support revocation.
- Administrative interfaces SHOULD support: elevated session verification;
  MFA enforcement.

### Logging Philosophy

- Logs MUST: remain structured; avoid secret leakage; support centralized
  collection; support incident investigation.
- Sensitive data MUST NOT appear in logs.

### Dependency Security

- Dependencies MUST: remain audited; remain maintained; remain
  version-controlled.
- The platform MUST minimize: dependency sprawl; abandoned modules;
  unnecessary attack surface.

### Operational Security

- Infrastructure MUST support: isolation; segmentation; patching;
  monitoring; incident response.
- Operational visibility is mandatory.

### Security Testing

- Mandatory testing includes: authorization testing; validation testing;
  regression testing; abuse testing; rate limit testing; input fuzzing.
- Critical flows MUST remain continuously testable.

### Incident Philosophy

- The platform MUST assume: compromise attempts; credential leaks; abuse
  campaigns; infrastructure failure.
- The architecture MUST support: containment; auditing; recovery;
  revocation; forensic investigation.

### Long-Term Security Goal

- The security architecture MUST remain: resilient; auditable; observable;
  distributed-safe; operationally sustainable; adaptable to future threats.
- Security is not a feature; it is a permanent architectural requirement.
- All future development MUST comply with this constitution.

## Consequences

- Deny-by-default RBAC + ABAC authorization, strict validation before any
  side effect, and sanitization of all user content make security review a
  standing part of every feature.
- Every security-sensitive operation produces an immutable, attributable
  audit record, which supports incident response and forensics at the cost
  of audit storage growth (partitioned per ADR 0051).
- A restrictive CSP without `unsafe-inline` constrains frontend work to
  external, same-origin scripts and styles.
- `t/09-prompt-alignment.t` currently reads `prompt/5.txt` to assert the
  domain integrity alignment text; it must be retargeted to this ADR before
  the prompt is deleted.
- Open conflicts:
  - WebAuthn/passkeys are SHOULD in the WebAuthn section, while
    WebAuthn-based MFA is mandatory in the MFA section and ADR 0049 makes
    WebAuthn and TOTP support mandatory. The repository has no WebAuthn or
    TOTP implementation yet.
  - HSTS is a mandatory browser protection, but
    `GPForum::Security::BrowserHeaders` does not emit
    `Strict-Transport-Security` and the shipped `deploy/nginx` and
    `deploy/caddy` configurations do not add it.
  - Attachments are stored by
    `GPForum::Service::Attachment::FilesystemStorage` on the local
    filesystem rather than object storage (a SHOULD here, a MUST in
    ADR 0050).

## Alignment

- ADR 0049 (foundation), ADR 0050 (infrastructure), ADR 0051 (audit and
  event storage), ADR 0052 (Perl security engineering), ADR 0057
  (authorization and moderation), ADR 0060 (API), ADR 0070 (permission
  matrix), ADR 0074 (privacy), ADR 0080 (content policy), ADR 0100 (domain
  integrity and authorization execution).
- ADR 0007 (websocket authorization policy), ADR 0016 (shared HTTP access,
  CSRF), ADR 0017 (realtime handshake access), ADR 0018 (cookie session
  ownership), ADR 0020 (audit record hashing), ADR 0022 (attachment
  download access), ADR 0047 (metrics token access).
- `lib/GPForum/Security/BrowserHeaders.pm`,
  `lib/GPForum/Bootstrap/Security.pm`, `lib/GPForum/Service/Password.pm`,
  `lib/GPForum/Service/SessionToken.pm`, `lib/GPForum/Web/Access.pm`,
  `lib/GPForum/Web/CookieSession.pm`,
  `lib/GPForum/Infrastructure/AuditRecord.pm`,
  `migrations/016_security_abuse_hardening.sql`.
- `t/48-browser-security.t`, `t/50-security-hardening.t`,
  `t/55-security-abuse-hardening.t`, `t/108-web-access.t`,
  `t/114-web-cookie-session.t`, `t/116-infrastructure-audit-record.t`,
  `t/09-prompt-alignment.t`.
- `SECURITY.md`, `docs/SECURITY_BASELINE.md`, `docs/SECURITY_HARDENING.md`.
