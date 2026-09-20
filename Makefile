.PHONY: architecture bootstrap check critic install-deps install-deps-postgres macports-env preflight staging-drill staging-drill-attachments stress-load stress-load-dry syntax system-perl test tidy

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

# Optional attachment filesystem + static deploy checklist; no PostgreSQL.
# Not part of `make check` or default CI.
staging-drill-attachments:
	script/staging-drill-attachments --json
