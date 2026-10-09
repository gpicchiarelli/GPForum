# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::EventIdempotencyRow;

use Mojo::Base 'GPForum::Test::Row';
use v5.40;

our $VERSION = '0.001';

has key  => undef;
has rows => sub { return {}; };

# The row lives in its resultset's map under its key, so a change made
# through any handle on it is the table's.
sub column_data {
    my ($self) = @_;

    return $self->rows->{ $self->key } || {};
}

sub completed_at {
    my ($self) = @_;

    return $self->get_column('completed_at');
}

sub created_at {
    my ($self) = @_;

    return $self->get_column('created_at');
}

sub event_id {
    my ($self) = @_;

    return $self->get_column('event_id');
}

sub remove_from_storage {
    my ($self) = @_;

    delete $self->rows->{ $self->key };

    return;
}

1;
