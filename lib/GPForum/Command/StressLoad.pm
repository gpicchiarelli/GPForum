# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::StressLoad;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Service::Operations::StressLoad;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;
const my %FLAG_OPTIONS => (
    '--help'    => 'help',
    '--json'    => 'format_json',
    '--human'   => 'format_human',
    '--dry-run' => 'dry_run',
    '--check'   => 'check',
);
const my %VALUE_OPTIONS => (
    '--profile'             => 'profile',
    '--concurrency'         => 'concurrency',
    '--requests-per-client' => 'requests_per_client',
    '--base-url'            => 'base_url',
    '--route'               => 'route',
    '--request-timeout'     => 'request_timeout',
    '--max-error-rate'      => 'max_error_rate',
    '--p95-limit-ms'        => 'p95_limit_ms',
);
const my %ALLOWED_PROFILES => map { $_ => 1 } qw(smoke 100 500 1000);

has load => undef;

# A usage croak becomes the documented usage exit instead of an uncaught
# exception: same text, on stderr, status 2, without croak's " at FILE line N".
# Anything else is rethrown, so a real failure is not relabelled as misuse.
sub run ( $self, @arguments ) {
    my $status = eval { return $self->_run(@arguments); };
    return $status if defined $status;

    my $error = GPForum::Command::Usage->trimmed($EVAL_ERROR);
    if ( !GPForum::Command::Usage->is_usage($error) ) {
        die "$error\n";
    }

    return GPForum::Command::Usage->error( undef, $error );
}

sub _run ( $self, @arguments ) {
    my $options = eval { return _options(@arguments) };
    if ( !$options ) {
        print {*STDERR} _trim($EVAL_ERROR)
          or croak 'failed to write stress-load usage error';
        return $EXIT_USAGE;
    }
    return _print_usage() if $options->{help};

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
        _apply_option( \%options, shift @arguments, \@arguments );
    }

    croak "Unsupported stress profile: $options{profile}\n" . _usage()
      if !_profile_allowed( $options{profile} );

    return \%options;
}

sub _apply_option ( $options, $argument, $arguments ) {
    if ( exists $FLAG_OPTIONS{$argument} ) {
        _set_flag( $options, $FLAG_OPTIONS{$argument} );
        return;
    }
    if ( exists $VALUE_OPTIONS{$argument} ) {
        _set_value( $options, $VALUE_OPTIONS{$argument}, $arguments );
        return;
    }

    croak "Unknown option: $argument\n" . _usage();
}

sub _set_flag ( $options, $name ) {
    if ( $name eq 'help' ) {
        $options->{help} = 1;
        return;
    }
    if ( $name eq 'format_json' ) {
        $options->{format} = 'json';
        return;
    }
    if ( $name eq 'format_human' ) {
        $options->{format} = 'human';
        return;
    }
    if ( $name eq 'dry_run' ) {
        $options->{dry_run} = 1;
        return;
    }
    if ( $name eq 'check' ) {
        $options->{check} = 1;
        return;
    }

    croak _usage();
}

sub _set_value ( $options, $name, $arguments ) {
    my $value = shift @{$arguments};
    croak _usage() if !defined $value;

    if ( $name eq 'profile' ) {
        $options->{profile} = $value;
        return;
    }
    if ( $name eq 'base_url' ) {
        $options->{base_url} = $value;
        return;
    }
    if ( $name eq 'route' ) {
        croak "Unsupported route: $value\n" . _usage()
          if $value !~ m{\A /}msx;
        push @{ $options->{routes} }, $value;
        return;
    }
    if ( $name eq 'concurrency' ) {
        $options->{concurrency} = _positive_integer($value);
        return;
    }
    if ( $name eq 'requests_per_client' ) {
        $options->{requests_per_client} = _positive_integer($value);
        return;
    }
    if ( $name eq 'request_timeout' ) {
        $options->{request_timeout} = _positive_integer($value);
        return;
    }
    if ( $name eq 'max_error_rate' ) {
        $options->{max_error_rate} = _non_negative_number($value);
        return;
    }
    if ( $name eq 'p95_limit_ms' ) {
        $options->{p95_limit_ms} = _positive_integer($value);
        return;
    }

    croak _usage();
}

sub _profile_allowed ($value) {
    return exists $ALLOWED_PROFILES{$value};
}

sub _positive_integer ($value) {
    croak _usage()
      if !defined $value || $value !~ /\A [1-9][[:digit:]]* \z/msx;

    return int $value;
}

sub _non_negative_number ($value) {
    croak _usage()
      if !defined $value
      || $value !~
      /\A (?: [[:digit:]]+ (?: [.] [[:digit:]]+ )? | [.] [[:digit:]]+ ) \z/msx;

    return 0 + $value;
}

sub _print_usage {
    print _usage() or croak 'failed to write stress-load usage';
    return 0;
}

sub _trim ($text) {
    $text =~ s/\s+\z//msx;
    return "$text\n";
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
