# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RacedSchema;

use Mojo::Base -base;
use v5.40;

use GPForum::Test::RacedResultSet;

our $VERSION = '0.001';

# A real schema whose next lookups in the named resultsets find nothing: what
# a writer sees when it looks just before a concurrent writer commits the same
# row. Only the look is scripted. The INSERT that follows, the unique
# violation PostgreSQL raises and the savepoint that recovers from it are the
# database's own -- the fake ORM had to imitate all three, and the aborted
# transaction besides.
#
#   GPForum::Test::RacedSchema->new(
#       schema => $schema,
#       misses => { AttachmentLink => 1 },
#   );
has misses => sub { return {}; };
has schema => undef;

sub resultset {
    my ( $self, $name ) = @_;

    my $resultset = $self->schema->resultset($name);
    return $resultset if !$self->misses->{$name};

    return GPForum::Test::RacedResultSet->new(
        inner => $resultset,
        name  => $name,
        raced => $self,
    );
}

# True once for each lookup in $name still to miss.
sub take_miss {
    my ( $self, $name ) = @_;

    my $due = $self->misses->{$name} // 0;
    return 0 if $due < 1;
    $self->misses->{$name} = $due - 1;

    return 1;
}

sub storage {
    my ($self) = @_;

    return $self->schema->storage;
}

sub txn_do {
    my ( $self, @arguments ) = @_;

    return $self->schema->txn_do(@arguments);
}

1;
