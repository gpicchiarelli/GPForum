# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SessionToken;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has value => 0;

sub issue_token {
    my ($self) = @_;

    $self->value( $self->value + 1 );

    return 'token-' . $self->value;
}

sub hash_token {
    my ( $self, $token ) = @_;

    return 'hash:' . ( $token || q{} );
}

1;
