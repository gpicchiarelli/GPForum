package GPForum::Worker::MinionGuard;

use strict;
use warnings;

use Carp    qw(croak);
use English qw(-no_match_vars);

our $VERSION = '0.001';

sub requested {
    my ( $class, $config, $program_name ) = @_;

    if ( $class->direct_outbox_process($program_name) ) {
        return 0;
    }
    if ( $config->minion_enabled ) {
        return 1;
    }

    return 0;
}

sub direct_outbox_process {
    my ( undef, $program_name ) = @_;

    if ( !defined $program_name ) {
        $program_name = $PROGRAM_NAME;
    }
    if ( $program_name =~ m{gpforum-outbox-dispatch \z}msx ) {
        return 1;
    }

    return 0;
}

sub wrap {
    my ( $class, $step ) = @_;

    my $ok = eval {
        $step->();
        return 1;
    };
    if ($ok) {
        return 1;
    }

    croak $class->unavailable($EVAL_ERROR);
}

sub assert_reachable {
    my ( $class, $minion ) = @_;

    if ( $class->reachable($minion) ) {
        return 1;
    }

    croak 'Minion PostgreSQL ping failed';
}

sub reachable {
    my ( $class, $minion ) = @_;

    my $db = $class->_database($minion);
    if ( !$db || !$db->can('ping') ) {
        return 0;
    }
    if ( $db->ping ) {
        return 1;
    }

    return 0;
}

sub unavailable {
    my ( $class, $error ) = @_;

    return 'Minion PostgreSQL backend is unavailable: '
      . $class->_error_detail($error);
}

sub _database {
    my ( $class, $minion ) = @_;

    my $backend = $class->_callable( $minion,  'backend' );
    my $pg      = $class->_callable( $backend, 'pg' );

    return $class->_callable( $pg, 'db' );
}

sub _callable {
    my ( undef, $object, $method ) = @_;

    if ( !$object || !$object->can($method) ) {
        return;
    }

    return $object->$method;
}

sub _error_detail {
    my ( undef, $error ) = @_;

    if ( defined $error && length $error ) {
        $error =~ s/\s+\z//msx;
        return $error;
    }

    return 'unknown error';
}

1;
