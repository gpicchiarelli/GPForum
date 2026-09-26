.PHONY: help install-deps-production pitr-drill partition-maintenance antivirus-check architecture bootstrap check cpan-audit critic dead-letter-check evidence-archive-check evidence-live evidence-meta evidence-validate install-deps install-deps-postgres macports-env mail-check mail-lifecycle-check preflight private-beta-checklist staging-drill staging-drill-attachments staging-host-verify stress-load stress-load-dry syntax system-perl test integration tidy

# All targets use the OS system Perl via script/gpforum-carton /
# script/gpforum-system-perl (not version managers or custom PREFIX builds).
#
# bin/ holds Perl application entrypoints; script/ holds repository tooling.
# A script/ wrapper drops the gpforum- prefix of the bin/ entrypoint it wraps,
# and no basename may exist in both directories. The rule is documented in
# docs/ENTRYPOINTS.md and enforced by script/architecture-check.

# The Makefile is the operator's front door for repository tasks, so it names
# its own targets rather than requiring a read of the file. Every target whose
# line carries a `## ` comment is listed.
help:
	@printf 'GPForum repository tasks\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[1m%-26s\033[0m %s\n", $$1, $$2}'
	@printf '\nOperational commands live in bin/; run `bin/gpforum` for those.\n'

system-perl: ## Verify the OS system Perl satisfies the floor
	script/gpforum-system-perl --preflight

macports-env: ## Check the MacPorts environment this host needs
	script/gpforum-macports-env --check

syntax: ## Compile every Perl file
	script/gpforum-carton exec script/perl-syntax-check

test: ## Run the test suite
	script/gpforum-carton exec prove -lr t

# Without a DSN every integration test skips, and a tier where everything
# skipped has not passed. This target refuses instead.
integration: ## Run the PostgreSQL integration tier (needs GPFORUM_DATABASE_DSN)
	@if [ -z "$$GPFORUM_DATABASE_DSN" ]; then \
	  echo 'integration: GPFORUM_DATABASE_DSN is not set; nothing was tested' >&2; \
	  echo 'integration: point it at a server where the user may CREATE DATABASE' >&2; \
	  exit 1; \
	fi
	script/gpforum-carton exec prove -lv -It/lib -r t/integration

# No --severity override. The profile declares `severity = brutal` and the
# baseline in etc/ was recorded at that level, so passing --severity 5 here
# meant `make check` compared a severity-5 run against a severity-1 baseline:
# it could not catch a new violation below severity 5, and reported most of
# the baseline as "not observed" every time.
critic: ## Run Perl::Critic against the baseline ratchet (slow: ~10 min)
	script/perlcritic

tidy: ## Check every file is perltidy-clean
	script/perltidy-check

architecture: ## Run the architecture invariants
	script/architecture-check

check: system-perl syntax test critic tidy architecture ## system-perl, syntax, test, critic, tidy, architecture

install-deps: ## Install runtime, test and develop dependencies
	script/bootstrap-deps

install-deps-postgres: ## Install dependencies including the postgres feature
	script/bootstrap-deps --postgres

install-deps-production: ## Install what a production host runs, without the develop tools
	script/bootstrap-deps --postgres --production

bootstrap: install-deps ## Install dependencies and prepare the checkout

preflight: ## Report whether this host can run GPForum
	script/system-preflight

# Optional operator drill; requires GPFORUM_DATABASE_DSN and pg_dump/pg_restore.
# Not part of `make check` or default CI.
staging-drill: ## Run the staging backup and restore drill
	script/staging-drill --json

# Optional HTTP stress/load harness against a running Hypnotoad/GPForum.
# Not part of `make check` or default CI. PROFILE=smoke|100|500|1000.
PROFILE ?= smoke
FORMAT ?= human
stress-load-dry: ## Plan the stress load without running it
	script/stress-load --dry-run --profile "$(PROFILE)" --$(FORMAT)

stress-load: ## Run the stress load generator
	@test -n "$(BASE_URL)" || (echo 'make stress-load requires BASE_URL=...' >&2; exit 2)
	script/stress-load --profile "$(PROFILE)" --base-url "$(BASE_URL)" --$(FORMAT)

# Optional attachment filesystem + deploy checklist (static + host when available).
# Not part of `make check` or default CI.
staging-drill-attachments: ## Run the attachment store drill
	script/staging-drill-attachments --json

# Optional identity mail delivery probe; uses GPFORUM_MAIL_* / SMTP settings.
# Not part of `make check` or default CI.
antivirus-check: ## Prove the upload antivirus detects the EICAR test file
	script/antivirus-check --human

mail-check: ## Send a test message through the configured mailer
	script/mail-check --json --dry-run

# Optional identity mail lifecycle drill (test transport). Not part of make check.
mail-lifecycle-check: ## Exercise the mail lifecycle end to end
	script/mail-lifecycle-check --json --simulate

# Optional dead-letter staging check (in-memory simulate). Not part of make check.
pitr-drill: ## Rehearse point-in-time recovery on a throwaway cluster
	script/pitr-drill

partition-maintenance: ## Plan next month's log partitions (add --apply to run)
	script/gpforum-carton exec bin/gpforum-partition-maintenance --plan

dead-letter-check: ## Report the dead-letter queue
	script/dead-letter-check --json --simulate

# Optional non-destructive staging host verify (repo artifacts; live flags optional).
# Not part of `make check` or default CI.
staging-host-verify: ## Verify a staging host against the deploy contract
	script/staging-host-verify --json

# Print-only private-beta prep commands/status. Does not run drills or claim
# readiness. See docs/ops/private-beta-checklist.md.
private-beta-checklist: ## Report the private-beta readiness checklist
	script/gpforum-private-beta-checklist --commands

# Print-only live staging-host-verify + stress-load + mail evidence commands.
# Does not start Hypnotoad or claim readiness. See docs/ops/staging-host.md.
evidence-live: ## Collect live runtime evidence
	script/gpforum-evidence-live --commands

# Stamp archived evidence with EvidenceMeta markers. Example:
#   make evidence-meta FILES='a.json' WRITE=1
evidence-meta: ## Summarise an evidence bundle
	@test -n "$(FILES)" || (echo 'make evidence-meta requires FILES="..."' >&2; exit 2)
	script/evidence-meta $(if $(WRITE),--write,) $(FILES)

# Validate archived evidence JSON (secrets/claims/shape). Not part of make check.
# Example: make evidence-validate FILES='a.json b.json'
FILES ?=
evidence-validate: ## Validate an evidence bundle
	@test -n "$(FILES)" || (echo 'make evidence-validate requires FILES="..."' >&2; exit 2)
	script/evidence-validate --json $(FILES)

# Audit the dependency lock against CPANSA advisories. Needs CPAN::Audit
# installed for the system Perl (a host tool, like Carton), so it is not part
# of `make check`. Accepted advisories live in etc/cpan-audit-ignore.txt.
cpan-audit: ## Check dependencies against CPAN security advisories
	script/cpan-audit

# Validate every archived ops evidence blob under docs/ops/evidence with
# --strict, skipping blobs whose .exit sidecar records a harness that never
# produced evidence. Not part of make check.
evidence-archive-check: ## Check the evidence archive is intact
	script/gpforum-evidence-archive-check
