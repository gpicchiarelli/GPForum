.PHONY: architecture bootstrap check critic install-deps install-deps-postgres preflight staging-drill syntax test tidy

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

check: syntax test critic tidy architecture

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
