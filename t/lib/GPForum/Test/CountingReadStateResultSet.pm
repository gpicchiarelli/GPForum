# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CountingReadStateResultSet;

use Carp qw(croak);
use Mojo::Base 'GPForum::Test::ReadStateResultSet';
use v5.40;

our $VERSION = '0.001';

# A read-state resultset that counts every insert it is asked for, and fails
# each one with $failure, an error that is not a unique violation, when set.
has create_attempts => 0;
has failure         => undef;    # optional: without it inserts run as usual

sub create {
    my ( $self, $row ) = @_;

    $self->create_attempts( $self->create_attempts + 1 );
    if ( defined $self->failure ) {
        croak $self->failure;
    }

    return $self->SUPER::create($row);
}

1;
