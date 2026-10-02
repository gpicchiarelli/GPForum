# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ReplicationDbh;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# A DBI handle that answers the replication catalog queries with what a test
# gives it, as DBD::Pg would: every value a string, booleans as 1 and 0. It
# is also its own schema and storage, so readiness and the metrics snapshot
# can be handed it directly.
has in_recovery      => 0;
has standbys         => sub { return []; };
has slots            => sub { return []; };
has standby_position => sub { return {}; };
has statements       => sub { return []; };

# The error every query dies with, when set: a database that cannot answer.
has failure => undef;

sub selectrow_array {
    my ( $self, $sql ) = @_;

    $self->_record($sql);

    return $self->in_recovery ? 1 : 0;
}

sub selectall_arrayref {
    my ( $self, $sql ) = @_;

    $self->_record($sql);

    return $sql =~ /\b pg_stat_replication \b/msx
      ? $self->standbys
      : $self->slots;
}

sub selectrow_hashref {
    my ( $self, $sql ) = @_;

    $self->_record($sql);

    return $self->standby_position;
}

sub storage {
    my ($self) = @_;

    return $self;
}

sub dbh {
    my ($self) = @_;

    return $self;
}

sub dbh_do {
    my ( $self, $code ) = @_;

    return $code->( $self, $self );
}

sub _record {
    my ( $self, $sql ) = @_;

    push @{ $self->statements }, $sql;
    die $self->failure . "\n" if defined $self->failure;

    return;
}

1;
