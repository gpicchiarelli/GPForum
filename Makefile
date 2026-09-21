.PHONY: architecture bootstrap check critic dead-letter-check evidence-live evidence-meta evidence-validate install-deps install-deps-postgres macports-env mail-check preflight private-beta-checklist staging-drill staging-drill-attachments staging-host-verify stress-load stress-load-dry syntax system-perl test tidy

# All targets use the OS system Perl via script/gpforum-carton /
# script/gpforum-system-perl (not version managers or custom PREFIX builds).

system-perl:
	script/gpforum-system-perl --preflight

macports-env:
	script/gpforum-macports-env --check

syntax:
	script/gpforum-carton exec script/perl-syntax-check

test:
	script/gpforum-carton exec prove -lr t

critic:
	script/perlcritic --severity 5

tidy:
	script/perltidy-check

architecture:
	script/architecture-check

check: system-perl syntax test critic tidy architecture

install-deps:
	script/bootstrap-deps

install-deps-postgres:
	script/bootstrap-deps --postgres

bootstrap: install-deps

preflight:
	script/system-preflight

# Optional operator drill; requires GPFORUM_DATABASE_DSN and pg_dump/pg_restore.
# Not part of `make check` or default CI.
staging-drill:
	script/staging-drill --json

# Optional HTTP stress/load harness against a running Hypnotoad/GPForum.
# Not part of `make check` or default CI. PROFILE=smoke|100|500|1000.
PROFILE ?= smoke
FORMAT ?= human
stress-load-dry:
	script/stress-load --dry-run --profile "$(PROFILE)" --$(FORMAT)

stress-load:
	@test -n "$(BASE_URL)" || (echo 'make stress-load requires BASE_URL=...' >&2; exit 2)
	script/stress-load --profile "$(PROFILE)" --base-url "$(BASE_URL)" --$(FORMAT)

# Optional attachment filesystem + deploy checklist (static + host when available).
# Not part of `make check` or default CI.
staging-drill-attachments:
	script/staging-drill-attachments --json

# Optional identity mail delivery probe; uses GPFORUM_MAIL_* / SMTP settings.
# Not part of `make check` or default CI.
mail-check:
	script/gpforum-mail-check --json --dry-run

# Optional dead-letter staging check (in-memory simulate). Not part of make check.
dead-letter-check:
	script/gpforum-dead-letter-check --json --simulate

# Optional non-destructive staging host verify (repo artifacts; live flags optional).
# Not part of `make check` or default CI.
staging-host-verify:
	script/staging-host-verify --json

# Print-only private-beta prep commands/status. Does not run drills or claim
# readiness. See docs/ops/private-beta-checklist.md.
private-beta-checklist:
	script/gpforum-private-beta-checklist --commands

# Print-only live staging-host-verify + stress-load + mail evidence commands.
# Does not start Hypnotoad or claim readiness. See docs/ops/staging-host.md.
evidence-live:
	script/gpforum-evidence-live --commands

# Stamp archived evidence with EvidenceMeta markers. Example:
#   make evidence-meta FILES='a.json' WRITE=1
evidence-meta:
	@test -n "$(FILES)" || (echo 'make evidence-meta requires FILES="..."' >&2; exit 2)
	script/gpforum-evidence-meta $(if $(WRITE),--write,) $(FILES)

# Validate archived evidence JSON (secrets/claims/shape). Not part of make check.
# Example: make evidence-validate FILES='a.json b.json'
FILES ?=
evidence-validate:
	@test -n "$(FILES)" || (echo 'make evidence-validate requires FILES="..."' >&2; exit 2)
	script/gpforum-evidence-validate --json $(FILES)
