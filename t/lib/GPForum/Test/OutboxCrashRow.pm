# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxCrashRow;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base 'GPForum::Test::OutboxRow';

our $VERSION = '0.001';

has crash_on_done => 1;

sub update {
    my ( $self, $changes ) = @_;

    if ( _should_crash( $self, $changes ) ) {
        $self->crash_on_done(0);
        croak 'crash after dispatch';
    }

    return $self->SUPER::update($changes);
}

sub _should_crash {
    my ( $self, $changes ) = @_;

    if ( !$self->crash_on_done ) {
        return 0;
    }
    if ( !$changes->{status} ) {
        return 0;
    }
    if ( $changes->{status} ne 'done' ) {
        return 0;
    }

    return 1;
}

1;
