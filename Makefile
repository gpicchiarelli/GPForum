.PHONY: architecture bootstrap check critic preflight test tidy

test:
	carton exec prove -lr t

critic:
	script/perlcritic --severity 5

tidy:
	script/perltidy-check

architecture:
	script/architecture-check

check: test critic tidy architecture

bootstrap:
	script/bootstrap-deps

preflight:
	script/system-preflight
