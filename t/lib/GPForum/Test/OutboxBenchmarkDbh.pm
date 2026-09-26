# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxBenchmarkDbh;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has ack_batches => 0;
has cursor      => 0;
has do_bind     => sub { return []; };
has do_sql      => sub { return []; };
has driver_name => 'Pg';
has rows        => sub { return []; };

sub selectall_arrayref {
    my ( $self, $sql, $attrs, @bind ) = @_;

    my $limit = _claim_limit(@bind);
    my @claimed;

    while ( $self->cursor < @{ $self->rows } && @claimed < $limit ) {
        push @claimed, $self->rows->[ $self->cursor ];
        $self->cursor( $self->cursor + 1 );
    }

    return \@claimed;
}

# The acknowledging UPDATE now uses RETURNING, so it is read rather than
# executed blind. Reporting back the ids it was given models the ordinary case
# where every claimed message is still held by this worker.
sub select_column {
    my ( $self, $sql, $attrs, @bind ) = @_;

    push @{ $self->do_sql },  $sql;
    push @{ $self->do_bind }, \@bind;
    if ( $sql =~ /\A UPDATE [ ] outbox_messages [ ] SET [ ] status/msx ) {
        $self->ack_batches( $self->ack_batches + 1 );
    }

    my @ids = @bind[ 2 .. $#bind - 2 ];

    return \@ids;
}

sub execute_statement {
    my ( $self, $sql, $attrs, @bind ) = @_;

    push @{ $self->do_sql },  $sql;
    push @{ $self->do_bind }, \@bind;
    if ( $sql =~ /\A UPDATE [ ] outbox_messages [ ] SET [ ] status/msx ) {
        $self->ack_batches( $self->ack_batches + 1 );
    }

    return 1;
}

sub _claim_limit {
    my (@bind) = @_;

    for my $value (@bind) {
        return $value
          if defined $value && $value =~ /\A [1-9][[:digit:]]* \z/msx;
    }

    return 1;
}

1;
