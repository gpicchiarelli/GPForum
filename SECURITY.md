# Security Policy

## Supported Branch

Security fixes target `main` until the project starts publishing release branches.

## Reporting A Vulnerability

Report vulnerabilities privately through GitHub Security Advisories:

https://github.com/gpicchiarelli/GPForum/security/advisories/new

Do not open public issues for exploitable behavior, credential exposure,
authorization bypasses, session defects, data leaks, or audit integrity failures.

## Security Expectations

- Authentication and session state are server-side.
- Authorization must be explicit and query-friendly.
- Audit records are append-oriented and must not be destructively modified.
- Sensitive user data belongs in dedicated tables and narrow services.
- New externally reachable behavior needs tests for failure and denial paths.

