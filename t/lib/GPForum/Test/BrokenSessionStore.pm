# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::BrokenSessionStore;

use Carp qw(croak);
use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# An identity store that fails every session validation while broken, and
# counts how often it was asked.

has broken => 1;
has calls  => 0;

sub validate_session {
    my ($self) = @_;

    $self->calls( $self->calls + 1 );
    croak 'session store unavailable' if $self->broken;

    return { ok => 1 };
}

1;
