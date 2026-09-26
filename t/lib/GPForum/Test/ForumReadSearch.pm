# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ForumReadSearch;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has keys => sub { return []; };
has rows => sub { return []; };

# The shape DBIx::Class gives: a reference to [ $sql, @bind ], the SQL already
# parenthesised. Here the binds are the values the search selected, so a
# condition using this as an -in subquery -- alone or in a UNION ALL of
# several -- matches what PostgreSQL would.
sub as_query {
    my ($self) = @_;

    my @keys         = @{ $self->keys };
    my $placeholders = join q{, }, (q{?}) x @keys;

    return \[ "(VALUES ($placeholders))", map { [ {} => $_ ] } @keys ];
}

sub single {
    my ($self) = @_;

    return $self->rows->[0];
}

sub all {
    my ($self) = @_;

    return @{ $self->rows };
}

sub count {
    my ($self) = @_;

    return scalar @{ $self->rows };
}

1;
