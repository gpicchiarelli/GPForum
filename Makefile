.PHONY: architecture bootstrap check critic preflight syntax test tidy

syntax:
	carton exec script/perl-syntax-check

test:
	carton exec prove -lr t

critic:
	script/perlcritic --severity 5

tidy:
	script/perltidy-check

architecture:
	script/architecture-check

check: syntax test critic tidy architecture

bootstrap:
	script/bootstrap-deps

preflight:
	script/system-preflight
