package GPForum::Service::Operations::Readiness;

use strict;
use warnings;

use Const::Fast;
use English     qw(-no_match_vars);
use Time::HiRes qw(time);
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Operations::OSPreflight;
use GPForum::Service::Operations::QueryBudget;

our $VERSION = '0.001';

const my $MILLISECONDS_PER_SECOND => 1000;
const my $MAX_ERROR_LENGTH        => 240;

has clock          => sub { return GPForum::Service::Clock->new; };
has environment    => 'development';
has runtime        => undef;
has runtime_policy => undef;
has schema         => undef;

sub check {
    my ($self) = @_;

    my $started = time;
    my @checks  = (
        $self->_db_check,
        $self->_runtime_check,
        $self->_os_preflight_check,
        $self->_runtime_enforcement_check,
        $self->_resultset_check('EventLog'),
        $self->_resultset_check('OutboxMessage'),
        $self->_resultset_check('ProjectionGeneration'),
        $self->_resultset_check('EndpointQueryBudget'),
        $self->_query_budget_drift_check,
    );

    return {
        status      => _overall_status( \@checks ),
        checks      => \@checks,
        environment => $self->environment,
        runtime     => $self->runtime ? $self->runtime->as_hash : {},
        timestamp   => $self->clock->now_iso8601,
        latency_ms  => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
    };
}

sub _runtime_check {
    my ($self) = @_;

    my $started = time;
    my $runtime = $self->runtime;
    return _failed_check( 'runtime', $started, 'runtime profile unavailable' )
      if !$runtime;

    my $profile = $runtime->as_hash;
    return _failed_check( 'runtime', $started, 'OS profile unavailable' )
      if !$profile->{os} || !$profile->{os}{name};

    return _ok_check( 'runtime', $started );
}

sub _db_check {
    my ($self) = @_;

    my $started = time;

    eval {
        my $storage = $self->schema->storage;
        my $dbh     = $storage->dbh;
        $dbh->selectrow_array('SELECT 1');
        1;
    } or return _failed_check( 'database', $started, $EVAL_ERROR );

    return _ok_check( 'database', $started );
}

sub _os_preflight_check {
    my ($self) = @_;

    my $started   = time;
    my $preflight = GPForum::Service::Operations::OSPreflight->new(
        runtime => $self->runtime,
        $self->_os_preflight_settings,
    )->check;

    return {
        name       => 'os_preflight',
        status     => $preflight->{status},
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
        checks     => $preflight->{checks},
    };
}

sub _runtime_enforcement_check {
    my ($self) = @_;

    return _ok_check( 'runtime_enforcement', time )
      if !$self->runtime_policy;

    my $started = time;
    my $check   = $self->runtime_policy->readiness_check;
    return {
        name       => $check->{name},
        status     => $check->{status},
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
        report     => $check->{report},
    };
}

sub _os_preflight_settings {
    my ($self) = @_;

    return () if !$self->runtime;

    my $settings = $self->runtime->os_preflight_settings || {};

    return %{$settings};
}

sub _resultset_check {
    my ( $self, $name ) = @_;

    my $started = time;

    eval {
        my $resultset = $self->schema->resultset($name);
        $resultset->search( {}, { rows => 1 } );
        1;
    } or return _failed_check( lc $name, $started, $EVAL_ERROR );

    return _ok_check( lc $name, $started );
}

sub _query_budget_drift_check {
    my ($self) = @_;

    my $started = time;
    my $report  = eval {
        return GPForum::Service::Operations::QueryBudget->new(
            schema => $self->schema )->drift_report;
    } or return _failed_check( 'query_budget_drift', $started, $EVAL_ERROR );

    return _failed_query_budget_check( $started, $report )
      if $report->{status} ne 'ok';

    return {
        name       => 'query_budget_drift',
        status     => 'ok',
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
        report     => $report,
    };
}

sub _failed_query_budget_check {
    my ( $started, $report ) = @_;

    return {
        name       => 'query_budget_drift',
        status     => 'fail',
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
        report     => $report,
    };
}

sub _ok_check {
    my ( $name, $started ) = @_;

    return {
        name       => $name,
        status     => 'ok',
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
    };
}

sub _failed_check {
    my ( $name, $started, $error ) = @_;

    return {
        name       => $name,
        status     => 'fail',
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
        error      => _compact_error($error),
    };
}

sub _overall_status {
    my ($checks) = @_;

    for my $check ( @{$checks} ) {
        return 'fail' if $check->{status} eq 'fail';
    }

    for my $check ( @{$checks} ) {
        return 'degraded' if $check->{status} eq 'degraded';
    }

    return 'ok';
}

sub _compact_error {
    my ($error) = @_;

    if ( !defined $error ) {
        $error = q{};
    }
    $error =~ s/\s+/ /gmsx;
    $error =~ s/\A\s+|\s+\z//gmsx;

    return substr $error, 0, $MAX_ERROR_LENGTH;
}

1;
