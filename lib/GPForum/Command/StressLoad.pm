# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::StressLoad;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Usage;
use GPForum::Service::Operations::StressLoad;
use GPForum::X::Usage;

our $VERSION = '0.001';

# Each flag sets one option to one value.
const my %FLAG_OPTIONS => (
    '--help'    => [ help    => 1 ],
    '--json'    => [ format  => 'json' ],
    '--human'   => [ format  => 'human' ],
    '--dry-run' => [ dry_run => 1 ],
    '--check'   => [ check   => 1 ],
);

# Each value option: the option it sets, and the shape a number it takes must
# have (none for text). A route is checked, and collected, on its own.
const my $POSITIVE_INTEGER => qr/\A [1-9][[:digit:]]* \z/msx;
const my %VALUE_OPTIONS => (
    '--profile'             => ['profile'],
    '--concurrency'         => [ concurrency         => $POSITIVE_INTEGER ],
    '--requests-per-client' => [ requests_per_client => $POSITIVE_INTEGER ],
    '--base-url'            => ['base_url'],
    '--route'               => ['routes'],
    '--request-timeout'     => [ request_timeout => $POSITIVE_INTEGER ],
    '--max-error-rate'      => [
        max_error_rate =>
qr/\A (?: [[:digit:]]+ (?: [.] [[:digit:]]+ )? | [.] [[:digit:]]+ ) \z/msx
    ],
    '--p95-limit-ms' => [ p95_limit_ms => $POSITIVE_INTEGER ],
);
const my %ALLOWED_PROFILES => map { $_ => 1 } qw(smoke 100 500 1000);

has load => undef;    # optional: a test's double; else the real one

# Misuse -- an option this command does not know, all its parser rejects --
# is the documented usage exit: the usage on stderr, status 2, without the
# " at bin/... line N." croak used to leave on it. A check that stops with an
# exception instead of evidence is a failure: 1 with its reason, redacted, on
# stderr and, as JSON, evidence saying fail (Command::Usage). It used to be
# rethrown with die, and an uncaught exception exits 255, or with whatever $!
# held: 2, misuse, after a failed file lookup.
sub run ( $self, @arguments ) {
    my $options;
    try {
        $options = _options(@arguments);
    }
    catch ($error) {
        return GPForum::Command::Usage->error( undef,
            GPForum::Command::Usage->trimmed($error) );
    };

    return _print_usage() if $options->{help};

    my $status;
    try {
        $status = $self->_run($options);
    }
    catch ($error) {
        return GPForum::Command::Usage->evidence_failure( $error,
            $options->{format}, { mode => 'stress-load' } );
    };

    return $status;
}

sub _run ( $self, $options ) {
    my $service  = $self->_service;
    my $evidence = $service->run($options);
    print $service->format_evidence( $evidence, $options->{format} )
      or croak 'failed to write stress-load evidence';

    return $service->exit_status($evidence);
}

sub _service ($self) {
    return $self->load if $self->load;

    return GPForum::Service::Operations::StressLoad->new;
}

sub _options (@arguments) {
    my %options = (
        format              => 'json',
        profile             => 'smoke',
        dry_run             => 0,
        check               => 0,
        help                => 0,
        base_url            => $ENV{GPFORUM_STRESS_BASE_URL},
        concurrency         => undef,
        requests_per_client => undef,
        request_timeout     => undef,
        max_error_rate      => undef,
        p95_limit_ms        => undef,
        routes              => [],
    );

    while (@arguments) {
        my $argument = shift @arguments;
        if ( exists $FLAG_OPTIONS{$argument} ) {
            my ( $name, $value ) = @{ $FLAG_OPTIONS{$argument} };
            $options{$name} = $value;
            next;
        }
        if ( !exists $VALUE_OPTIONS{$argument} ) {
            GPForum::X::Usage->throw(
                message => "Unknown option: $argument\n" . _usage() );
        }

        _set_value( \%options, $VALUE_OPTIONS{$argument}, shift @arguments );
    }

    if ( !exists $ALLOWED_PROFILES{ $options{profile} } ) {
        GPForum::X::Usage->throw(
            message => "Unsupported stress profile: $options{profile}\n"
              . _usage() );
    }

    # The usage says --base-url is required unless --dry-run, so leaving it
    # out is misuse, 2. The service refusing it surfaced as an uncaught
    # exception: 255, a status the contract has no meaning for.
    if (   !$options{help}
        && !$options{dry_run}
        && !_has_text( $options{base_url} ) )
    {
        GPForum::X::Usage->throw(
            message => "--base-url is required unless --dry-run\n" . _usage() );
    }

    return \%options;
}

sub _set_value ( $options, $option, $value ) {
    my ( $name, $shape ) = @{$option};
    if ( !defined $value || ( $shape && $value !~ $shape ) ) {
        GPForum::X::Usage->throw( message => _usage() );
    }

    if ( $name eq 'routes' ) {
        if ( $value !~ m{\A /}msx ) {
            GPForum::X::Usage->throw(
                message => "Unsupported route: $value\n" . _usage() );
        }
        push @{ $options->{routes} }, $value;
        return;
    }
    $options->{$name} = $shape ? 0 + $value : $value;

    return;
}

sub _has_text ($value) {
    return defined $value && length $value;
}

sub _print_usage {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() );
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-stress-load [options]

Operator-runnable HTTP stress/load harness for a running Hypnotoad/GPForum
instance. Profiles map to concurrent in-flight request slots (equivalent to
100 / 500 / 1000 concurrent users for capacity evidence).

  --profile NAME              smoke|100|500|1000 (default smoke)
  --concurrency N             override profile concurrency
  --requests-per-client N     requests each concurrent slot issues
  --base-url URL              required unless --dry-run
                              (or set GPFORUM_STRESS_BASE_URL)
  --route /path               repeatable; defaults to seeded hot paths
  --request-timeout SECONDS   per-request timeout (default 30)
  --max-error-rate PCT        --check threshold (default 1)
  --p95-limit-ms N            --check threshold (default 2000)
  --check                     non-zero exit when thresholds fail
  --dry-run                   print plan only; no HTTP traffic
  --json                      JSON evidence (default)
  --human                     human summary lines
  --help                      show this help

Prerequisites:
  - Running Hypnotoad (or proxy) reachable at --base-url
  - Migrated PostgreSQL with performance seed data for forum routes
  - GPFORUM_DATABASE_DSN configured for the target app (not this client)

Examples:
  script/stress-load --dry-run --profile 100 --human
  script/stress-load --profile smoke --base-url http://127.0.0.1:8080 --human
  script/stress-load --profile 100 --base-url https://forum.example --check --json
  make stress-load PROFILE=smoke BASE_URL=http://127.0.0.1:8080

Not part of make check / default CI.
USAGE
}

1;
