# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Worker::MinionGuard;

use v5.40;

use English qw(-no_match_vars);

use GPForum::X::Unavailable;

our $VERSION = '0.001';

sub requested ( $class, $config, $program_name = undef ) {
    if ( $class->direct_outbox_process($program_name) ) {
        return 0;
    }
    if ( $config->minion_enabled ) {
        return 1;
    }

    return 0;
}

sub direct_outbox_process ( $, $program_name ) {
    if ( !defined $program_name ) {
        $program_name = $PROGRAM_NAME;
    }
    if ( $program_name =~ m{gpforum-outbox-dispatch \z}msx ) {
        return 1;
    }

    return 0;
}

sub wrap ( $class, $step ) {
    try {
        $step->();
    }
    catch ($error) {
        GPForum::X::Unavailable->throw(
            message => $class->unavailable($error),
            cause   => $error,
        );
    };

    return 1;
}

sub assert_reachable ( $class, $minion ) {
    if ( $class->reachable($minion) ) {
        return 1;
    }

    GPForum::X::Unavailable->throw(
        message => 'Minion PostgreSQL ping failed' );
}

# _database reaches a db only through Minion::Backend::Pg's Mojo::Pg, whose
# database handle always has ping.
sub reachable ( $class, $minion ) {
    my $db = $class->_database($minion);
    if ( !$db ) {
        return 0;
    }
    if ( $db->ping ) {
        return 1;
    }

    return 0;
}

sub unavailable ( $class, $error ) {
    return 'Minion PostgreSQL backend is unavailable: '
      . $class->_error_detail($error);
}

sub _database ( $class, $minion ) {
    my $backend = $class->_callable( $minion,  'backend' );
    my $pg      = $class->_callable( $backend, 'pg' );

    return $class->_callable( $pg, 'db' );
}

# A backend other than Minion::Backend::Pg has no pg, nor a db to ping: it is
# reported unreachable rather than probed.
sub _callable ( $, $object, $method ) {
    if ( !$object || !$object->can($method) ) {
        return undef;
    }

    return $object->$method;
}

sub _error_detail ( $, $error ) {
    if ( defined $error && length $error ) {
        $error =~ s/\s+\z//msx;
        return $error;
    }

    return 'unknown error';
}

1;
