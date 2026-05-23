package GPForum::Service::Operations::Readiness;

use strict;
use warnings;

use Const::Fast;
use English     qw(-no_match_vars);
use Time::HiRes qw(time);
use Mojo::Base -base;

use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $MILLISECONDS_PER_SECOND => 1000;
const my $MAX_ERROR_LENGTH        => 240;

has clock       => sub { return GPForum::Service::Clock->new; };
has environment => 'development';
has runtime     => undef;
has schema      => undef;

sub check {
    my ($self) = @_;

    my $started = time;
    my @checks  = (
        $self->_db_check,
        $self->_runtime_check,
        $self->_resultset_check('EventLog'),
        $self->_resultset_check('OutboxMessage'),
        $self->_resultset_check('ProjectionGeneration'),
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
