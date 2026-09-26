# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::EventIdempotencyResultSet;

use strict;
use warnings;

use Carp qw(croak);
use GPForum::Test::EventIdempotencyRow;
use GPForum::Test::EventIdempotencySearch;
use GPForum::Infrastructure::UniqueConflict;
use Mojo::Base -base;

our $VERSION = '0.001';

has fail_error => undef;
has rows       => sub { return {}; };

sub find {
    my ( $self, $query ) = @_;

    my $key = _lookup_key($query);
    my $row = $self->rows->{$key};
    return $row if !$row;

    return GPForum::Test::EventIdempotencyRow->new(
        key  => $key,
        rows => $self->rows,
    );
}

sub create {
    my ( $self, $row ) = @_;

    if ( defined $self->fail_error ) {
        croak $self->fail_error;
    }

    my $key = $row->{idempotency_key};
    if ( exists $self->rows->{$key} ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'event_idempotency_keys_pkey');
    }

    $self->rows->{$key} = $row;

    return $row;
}

# The store reclaims an abandoned claim with a single conditional UPDATE, so
# the double has to model search(...)->update(...) rather than a plain find.
# Returning a row object from find() is what lets the store call update and
# delete on it the way DBIx::Class would.
# DBIx::Class's context-proof form of search. lib/ calls it wherever it means a
# resultset, because search itself returns every row in list context.
sub search_rs {
    my ( $self, @arguments ) = @_;

    return $self->search(@arguments);
}

sub search {
    my ( $self, $query ) = @_;

    return GPForum::Test::EventIdempotencySearch->new(
        query => $query,
        rows  => $self->rows,
    );
}

sub _lookup_key {
    my ($query) = @_;

    if ( ref $query eq 'HASH' ) {
        return $query->{idempotency_key};
    }

    return $query;
}

1;
