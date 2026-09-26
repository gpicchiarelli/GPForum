# GPForum CI

The pipeline is authoritative ([prompt/11.txt](../prompt/11.txt)): code does not
bypass automated validation, security scanning, critic enforcement or testing.
This page maps every GPForum target to the workflow that proves it, and every
mandatory pipeline stage to where it runs.

Workflows live in [.github/workflows](../.github/workflows). Every job installs
the locked tree the same way an operator does — the OS system Perl,
`script/bootstrap-deps`, `cpanfile.snapshot` — so a green run means the
documented host instructions work, not that CI has a private path.

## Platform targets

| Target | Workflow | Runner | Trigger | Blocks merge |
| --- | --- | --- | --- | --- |
| Ubuntu (primary quality gate) | [ci.yml](../.github/workflows/ci.yml) | `ubuntu-latest`, system `/usr/bin/perl` | every push and pull request to `main` | yes |
| Debian stable | [platform-debian.yml](../.github/workflows/platform-debian.yml) | `debian:trixie` container | code paths on `main`, weekly, manual | no |
| FreeBSD | [platform-freebsd.yml](../.github/workflows/platform-freebsd.yml) | FreeBSD VM on an Ubuntu runner | OS/rc paths on `main`, weekly, manual | no |
| macOS developer host | [platform-macos.yml](../.github/workflows/platform-macos.yml) | `macos-latest` with MacPorts | OS/launchd paths on `main`, weekly, manual | no |

Debian and FreeBSD are the deployment platforms named in the README and in
[deploy/](../deploy); macOS is the supported developer host. The macOS workflow
splits into a fast MacPorts system-Perl contract job and a scheduled full gate,
because MacPorts publishes no `App::cpanminus` or Carton port for Perl 5.38+ and
the laptop path has to bootstrap Carton from MetaCPAN with core `CPAN.pm`.

## Database targets

| Target | Workflow | What it proves |
| --- | --- | --- |
| PostgreSQL 16, 17, 18 | [postgres-matrix.yml](../.github/workflows/postgres-matrix.yml) | migration plan, apply, apply-again idempotency, every PostgreSQL integration test in `t/integration/` (`make integration`), `bin/gpforum-platform-check --with-db`, and the fresh/upgrade/dump-restore drill with a version-matched `pg_dump` |

`ci.yml` keeps one server (PostgreSQL 16) in the blocking gate; the matrix runs
on migration and schema paths, nightly, and on demand.

## Readiness targets

The README status table tracks three readiness targets. CI covers what can be
proven without a staging host; it never converts an operator residual into a
claim.

| Readiness target | Covered by CI | Still operator work |
| --- | --- | --- |
| Local, personal use | `ci.yml`, `postgres-matrix.yml`, `platform-*.yml` | — |
| Private beta | [ops-drills.yml](../.github/workflows/ops-drills.yml): backup/restore, attachment restore, deploy templates, host verify, mail transport probe, mail lifecycle, dead letters, stress-load planning, evidence validation | staging TLS, SMTP `--send`, stress 100/500/1000 against the target, unit install — see [ops/private-beta-checklist.md](ops/private-beta-checklist.md) |
| Public production | [deploy-units.yml](../.github/workflows/deploy-units.yml), [release.yml](../.github/workflows/release.yml), `postgres-matrix.yml` | live staging numbers, rehearsed rollback on the target host |

A green `ops-drills.yml` run does not claim private-beta readiness. The drills
run in their offline, simulate and dry-run modes, exactly as
`script/gpforum-private-beta-checklist` describes them.

## Mandatory pipeline stages

[prompt/11.txt](../prompt/11.txt) requires every pipeline to cover these stages.

| Stage | Where it runs |
| --- | --- |
| Dependency validation | `ci.yml` (`script/gpforum-carton check`), every platform workflow, `release.yml` |
| Static analysis | `ci.yml` (`script/perlcritic`, `script/perl-syntax-check`, `script/architecture-check`), `security.yml` (actionlint, shellcheck) |
| Formatting validation | `ci.yml` (`script/perltidy-check`) |
| Test execution | `ci.yml`, `platform-debian.yml`, `platform-freebsd.yml`, `platform-macos.yml`, `postgres-matrix.yml` |
| Coverage validation | `ci.yml` (`script/coverage`, `cover_db/` artifact) |
| Profiling smoke validation | [performance.yml](../.github/workflows/performance.yml) (`script/profile-route` under Devel::NYTProf, benchmark sweeps) |
| Security scanning | [security.yml](../.github/workflows/security.yml) (CPANSA advisories, license review, gitleaks, workflow and shell linting, OpenSSF Scorecard) |
| Artifact creation | `release.yml` (reproducible `git archive` tarball, Carton vendor bundle, `SHA256SUMS`, build provenance attestation) |
| Deployment validation | `deploy-units.yml` (`systemd-analyze verify`, `nginx -t`, `caddy validate`, `sh -n` on the rc(8) unit, deploy checklist drill) |
| Migration validation | `postgres-matrix.yml` (plan, apply, idempotent re-apply, fresh/upgrade/dump-restore drill) |
| Accessibility gates | `ci.yml` test suite (`t/65-accessible-theme.t`, `t/35-forum-accessible-ssr.t`, the `*-access.t` authorization suite) per [prompt/46.txt](../prompt/46.txt) |

## Running the gates locally

```sh
make check                          # the ci.yml quality gate
make cpan-audit                     # CPANSA advisories against the lock
make evidence-archive-check         # archived ops evidence, --strict
make staging-drill                  # migration fresh/upgrade/dump-restore
make staging-drill-attachments      # attachment restore + deploy templates
make mail-lifecycle-check           # identity mail under the test transport
make dead-letter-check              # dead-letter lifecycle, in memory
make stress-load-dry                # stress-load plan, no HTTP traffic
make staging-host-verify            # non-destructive host verify
make private-beta-checklist         # print-only preparation status
```

`make cpan-audit` needs CPAN::Audit installed for the system Perl. It is a host
tool, like Carton: it audits `cpanfile.snapshot`, so it must not become part of
it.

```sh
sudo "$(script/gpforum-system-perl --print)" -S cpanm -M https://cpan.metacpan.org/ CPAN::Audit
```

## Pipeline rules

- **Actions are pinned to a commit SHA** with a version comment. `security.yml`
  fails the build when an unpinned `uses:` appears in a workflow or in the
  composite action.
- **Tool downloads are checksummed.** gitleaks and actionlint are installed from
  pinned release archives verified with `sha256sum --check --strict`.
- **Workflow permissions start at `contents: read`** and are widened per job
  only where a job needs it (SARIF upload, release creation, attestation).
- **Secrets never enter the repository.** [.gitleaks.toml](../.gitleaks.toml)
  scopes the scan; its only content allowlist covers `t/` fixture hashes, which
  exist to prove hashing and redaction behaviour.
- **Accepted advisories are documented.**
  [etc/cpan-audit-ignore.txt](../etc/cpan-audit-ignore.txt) carries a reason, a
  mitigation and a review trigger per entry. Anything else fails the scan.
- **The dependency cache is keyed on the lock** (`cpanfile`,
  `cpanfile.postgres`, `cpanfile.snapshot`), the runner OS and architecture, and
  the system Perl version, so a cache hit can never change the installed tree.
- **Evidence is validated, not trusted.** Every JSON blob a workflow produces
  goes through `script/gpforum-evidence-validate --strict`, and archived
  evidence goes through `script/gpforum-evidence-archive-check`.

## Shared setup

[.github/actions/setup-gpforum-perl](../.github/actions/setup-gpforum-perl/action.yml)
is the composite action every Ubuntu workflow uses: system packages, Carton for
the system Perl, the system-Perl assertion, the dependency cache, and
`script/bootstrap-deps`. `ci.yml` keeps those steps inline on purpose — it is
the canonical gate, pinned command by command by `t/18-github-project.t`, so the
contract test reads the pipeline itself rather than an indirection.
