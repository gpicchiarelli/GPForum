# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::PlatformCheck;

use Carp qw(croak);
use Const::Fast;
use List::Util qw(any);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Runtime;
use GPForum::Service::Operations::OSPreflight;
use GPForum::Service::Operations::Profile;
use GPForum::Service::Operations::QueryBudget;

our $VERSION = '0.001';

const my %CHECK_FOR => (
    '--local'          => { include_db => 0, strict => 0 },
    '--strict-local'   => { include_db => 0, strict => 1 },
    '--with-db'        => { include_db => 1, strict => 0 },
    '--strict-with-db' => { include_db => 1, strict => 1 },
);
const my %RANK => ( ok => 0, degraded => 1, fail => 2 );

has config  => undef;    # optional: read from the environment otherwise
has runtime => undef;    # optional: built from the configuration otherwise
has schema  => undef;    # optional: connected only for --with-db

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $options = _options(@arguments);
    return GPForum::Command::Usage->error( $options->{error}, _usage() )
      if defined $options->{error};

    return $self->_platform_check($options);
}

sub local_check ($self) {
    return $self->_platform_check( _check_for('--local') );
}

sub strict_local_check ($self) {
    return $self->_platform_check( _check_for('--strict-local') );
}

sub with_db_check ($self) {
    return $self->_platform_check( _check_for('--with-db') );
}

sub strict_with_db_check ($self) {
    return $self->_platform_check( _check_for('--strict-with-db') );
}

sub _platform_check ( $self, $options ) {
    my $checks;
    try {
        $checks = $self->_checks($options);
    }
    catch ($error) {
        return GPForum::Command::Usage->failure( $error,
            _json_failure($options) );
    };

    my $exit = _exit_status( $checks, $options->{strict} );
    if ( $options->{json} ) {
        GPForum::Command::Usage->json( \*STDOUT,
            _json_document( $checks, $options, $exit ) );
        return $exit;
    }

    for my $check ( @{$checks} ) {
        print "$check->{name} status=$check->{status}\n"
          or croak 'failed to write platform check';
    }

    return $exit;
}

sub _checks ( $self, $options ) {
    my @checks = ( $self->_os_preflight_check, $self->_profile_check );
    if ( $options->{include_db} ) {
        push @checks, $self->_query_budget_drift_check;
    }

    return \@checks;
}

# The overall status is the worst of the checks, so a degraded host reads as
# degraded whether or not --strict made that a failure; the exit status says
# which it was.
sub _json_document ( $checks, $options, $exit ) {
    my $worst = 'ok';
    for my $check ( @{$checks} ) {
        if ( _rank( $check->{status} ) > _rank($worst) ) {
            $worst = $check->{status};
        }
    }

    return {
        %{ _json_head($options) },
        checks => [
            map {
                {
                    name   => $_->{name},
                    report => $_->{report},
                    status => $_->{status}
                }
            } @{$checks}
        ],
        status => $exit ? 'fail' : $worst,
    };
}

# A status this command does not know ranks as degraded: worse than ok,
# without claiming a failure the check did not report.
sub _rank ($status) {
    return exists $RANK{$status} ? $RANK{$status} : $RANK{degraded};
}

sub _json_head ($options) {
    return {
        checks  => [],
        command => 'gpforum-platform-check',
        mode    => $options->{mode},
        strict  => $options->{strict},
    };
}

sub _json_failure ($options) {
    return if !$options->{json};

    return ( \*STDOUT, _json_head($options) );
}

sub _os_preflight_check ($self) {
    my $report = GPForum::Service::Operations::OSPreflight->new(
        runtime => $self->_runtime )->check;

    return {
        name   => 'os_preflight',
        status => $report->{status},
        report => $report,
    };
}

sub _profile_check ($self) {
    my $result =
      GPForum::Service::Operations::Profile->new->evaluate( $self->_config );

    return {
        name   => 'operational_profile',
        report => $result,
        status => $result->{ok} ? 'ok' : 'fail',
    };
}

sub _query_budget_drift_check ($self) {
    my $report =
      GPForum::Service::Operations::QueryBudget->new( schema => $self->_schema )
      ->drift_report;

    return {
        name   => 'query_budget_drift',
        status => $report->{status},
        report => $report,
    };
}

sub _config ($self) {
    if ( $self->config ) {
        return $self->config;
    }

    return GPForum::Config->from_environment;
}

sub _runtime ($self) {
    if ( $self->runtime ) {
        return $self->runtime;
    }

    return GPForum::Runtime->from_config( $self->_config );
}

sub _schema ($self) {
    if ( $self->schema ) {
        return $self->schema;
    }

    require GPForum::Schema;
    return GPForum::Schema->connect_from_config( $self->_config );
}

sub _exit_status ( $checks, $strict ) {
    return 1 if any { $_->{status} eq 'fail' } @{$checks};
    return 0 if !$strict;

    return ( any { $_->{status} ne 'ok' } @{$checks} ) ? 1 : 0;
}

# Every argument is read: `--local --bogus` used to run --local and exit 0,
# and a second mode was ignored rather than refused.
sub _options (@arguments) {
    my %options = ( json => 0 );
    for my $argument (@arguments) {
        if ( $argument eq '--json' ) {
            $options{json} = 1;
            next;
        }
        return { error => "unknown option $argument" }
          if !exists $CHECK_FOR{$argument};
        return { error => 'choose one of ' . join q{, }, sort keys %CHECK_FOR }
          if defined $options{mode} && $options{mode} ne $argument;
        $options{mode} = $argument;
    }
    $options{mode} //= '--local';

    return { %{ _check_for( $options{mode} ) }, json => $options{json} };
}

sub _check_for ($flag) {
    return { %{ $CHECK_FOR{$flag} }, json => 0, mode => substr $flag, 2 };
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-platform-check [--local|--strict-local|--with-db|--strict-with-db] [--json]

Reports whether this host satisfies the platform prerequisites.

  --local             check what can be checked without a database
  --strict-local      as --local, but warnings fail the run
  --with-db           also check the database connection and settings
  --strict-with-db    as --with-db, but warnings fail the run
  --json              one JSON object on stdout instead of lines
  --help              show this help

Exit status: 0 success, 1 a check failed, 2 usage error.
USAGE
}

1;
