# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxDbh;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has attrs        => sub { return {}; };
has bind         => sub { return []; };
has claimed_ids  => sub { return []; };
has claimed_rows => sub { return []; };
has driver_name  => 'Pg';
has do_bind      => sub { return []; };
has do_sql       => sub { return []; };
has sql          => q{};

# Ids the guarded UPDATE ... RETURNING reports as actually acknowledged. undef
# means "every id that was asked for", which is the common case; setting it
# models a message whose lease expired and was re-claimed elsewhere.
has acknowledged_ids => undef;

sub selectall_arrayref {
    my ( $self, $sql, $attrs, @bind ) = @_;

    $self->sql($sql);
    $self->attrs($attrs);
    $self->bind( \@bind );

    return $self->claimed_rows if @{ $self->claimed_rows };

    return [ map { { outbox_id => $_ } } @{ $self->claimed_ids } ];
}

sub select_column {
    my ( $self, $sql, $attrs, @bind ) = @_;

    push @{ $self->do_sql },  $sql;
    push @{ $self->do_bind }, \@bind;

    return $self->acknowledged_ids if defined $self->acknowledged_ids;

    # Without an explicit answer, report back the ids the statement was given:
    # the bind list is status, timestamp, ids..., worker, status.
    my @ids = @bind[ 2 .. $#bind - 2 ];

    return \@ids;
}

sub execute_statement {
    my ( $self, $sql, $attrs, @bind ) = @_;

    push @{ $self->do_sql },  $sql;
    push @{ $self->do_bind }, \@bind;

    return 1;
}

1;
