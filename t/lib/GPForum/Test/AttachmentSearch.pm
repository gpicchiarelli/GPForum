# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::AttachmentSearch;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# The rows an attachment search found, as GPForum::Test::AttachmentResultSet
# hands them back.

has rows => sub { return []; };

sub all {
    my ($self) = @_;

    return @{ $self->rows };
}

sub single {
    my ($self) = @_;

    return $self->rows->[0];
}

# DBIx::Class's resultset update: every matched row, and the count -- "0E0"
# when nothing matched, which is true in boolean context, as DBI reports it.
sub update {
    my ( $self, $changes ) = @_;

    my $count = 0;
    for my $row ( @{ $self->rows } ) {
        $row->update($changes);
        $count++;
    }

    return $count ? $count : '0E0';
}

1;
