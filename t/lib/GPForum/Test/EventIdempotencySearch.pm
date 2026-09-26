# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::EventIdempotencySearch;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# Models search(...)->update(...): the store reclaims an abandoned claim with
# one conditional UPDATE, and a double that only supports find() cannot show
# whether that statement matched anything.

has query => sub { return {}; };
has rows  => sub { return {}; };

sub update {
    my ( $self, $changes ) = @_;

    my $updated = 0;
    for my $key ( sort keys %{ $self->rows } ) {
        next if !$self->_matches($key);
        my $row = $self->rows->{$key};
        @{$row}{ keys %{$changes} } = values %{$changes};
        $updated++;
    }

    # DBI reports "no rows matched, but the statement succeeded" as the string
    # "0E0", which is TRUE in boolean context. Returning a plain 0 here would
    # let a caller that tests the result for truth pass the unit tier and fail
    # against a real database -- which is exactly what happened.
    return $updated ? $updated : '0E0';
}

sub _matches {
    my ( $self, $key ) = @_;

    my $query = $self->query;
    my $row   = $self->rows->{$key};

    return 0
      if exists $query->{idempotency_key}
      && $key ne $query->{idempotency_key};
    return 0
      if exists $query->{completed_at}
      && defined $row->{completed_at};

    return $self->_matches_created( $row, $query->{created_at} );
}

sub _matches_created {
    my ( undef, $row, $condition ) = @_;

    return 1 if !defined $condition;
    return 1 if ref $condition ne 'HASH';

    my $before = $condition->{q{<}};
    return 1 if !defined $before;
    return 0 if !defined $row->{created_at};

    return $row->{created_at} lt $before ? 1 : 0;
}

1;
