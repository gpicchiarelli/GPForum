# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SearchSearch;

use strict;
use warnings;

use Mojo::Base -base;
use Scalar::Util qw(refaddr);

our $VERSION = '0.001';

BEGIN {
    *delete = \&_delete_rows;
}

has candidate_attrs => undef;
has resultset       => undef;
has rows            => sub { return []; };

sub as_rows {
    my ($self) = @_;

    return @{ $self->rows };
}

sub all {
    my ($self) = @_;

    return @{ $self->rows };
}

# DBIx::Class's way to make a search the FROM of another query, as Searcher
# ranks its newest candidates. The rows stay the ones matched. The attributes
# the candidates were chosen with are kept here, because the outer query's
# replace them as the resultset's last ones.
sub as_subselect_rs {
    my ($self) = @_;

    my $resultset = $self->resultset;

    return GPForum::Test::SearchSearch->new(
        candidate_attrs => $resultset ? $resultset->last_attrs : undef,
        resultset       => $resultset,
        rows            => [ @{ $self->rows } ],
    );
}

# The outer query over a subselect: its attributes become the resultset's last
# ones, as a direct search's would, and its row limit applies. It has no WHERE
# of its own; the candidates were already filtered.
sub search_rs {
    my ( $self, undef, $attrs ) = @_;

    my $resultset = $self->resultset;
    if ($resultset) {
        $resultset->last_attrs($attrs);
    }
    my @rows  = @{ $self->rows };
    my $limit = ref $attrs eq 'HASH' ? $attrs->{rows} : undef;
    if ( $limit && @rows > $limit ) {
        splice @rows, $limit;
    }

    return GPForum::Test::SearchSearch->new(
        candidate_attrs => $self->candidate_attrs,
        resultset       => $resultset,
        rows            => \@rows,
    );
}

# The rows this search matched leave the resultset, as a DELETE would take
# them, and the count is what DBI reports.
sub _delete_rows {
    my ($self) = @_;

    my $resultset = $self->resultset;
    push @{ $resultset->deleted }, $resultset->last_query;

    my %gone = map { refaddr($_) => 1 } @{ $self->rows };
    @{ $resultset->rows } =
      grep { !$gone{ refaddr($_) } } @{ $resultset->rows };

    return scalar keys %gone;
}

1;
