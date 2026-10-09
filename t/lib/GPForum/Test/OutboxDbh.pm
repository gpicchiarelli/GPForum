# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxDbh;

use Const::Fast;
use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# What the dispatcher's every write after the claim ends on: this message,
# this worker, still running -- and which row, if any, it updated.
const my $OWNED_GUARD =>
  'WHERE outbox_id = ? AND locked_by = ? AND status = ? RETURNING outbox_id';

# Where in such a write's binds the message's id is: third from last, before
# the worker and the running status.
const my $MESSAGE_ID => -3;

has attrs        => sub { return {}; };
has bind         => sub { return []; };
has claimed_ids  => sub { return []; };
has claimed_rows => sub { return []; };
has driver_name  => 'Pg';
has do_bind      => sub { return []; };
has do_sql       => sub { return []; };
has sql          => q{};

# Ids the dispatcher's guarded UPDATE ... RETURNING still finds this worker's.
# undef means every one, which is the common case; setting it models a
# message whose lease expired and was re-claimed by another worker.
has owned_ids => undef;

sub selectall_arrayref {
    my ( $self, $sql, $attrs, @bind ) = @_;

    $self->sql($sql);
    $self->attrs($attrs);
    $self->bind( \@bind );

    return $self->claimed_rows if @{ $self->claimed_rows };

    return [ map { { outbox_id => $_ } } @{ $self->claimed_ids } ];
}

# Each write after the claim names one message; its id comes back while the
# message is still owned.
sub select_column {
    my ( $self, $sql, $attrs, @bind ) = @_;

    push @{ $self->do_sql },  $sql;
    push @{ $self->do_bind }, \@bind;

    my $id = $bind[$MESSAGE_ID];
    if ( defined $self->owned_ids ) {
        return [ grep { $_ eq $id } @{ $self->owned_ids } ];
    }

    return [$id];
}

# The writes made after the claim, in order, as kind:id. The kind is renew
# for a renewal, which writes locked_until alone, and otherwise the status
# written: done, failed or cancelled. A write not guarded by $OWNED_GUARD,
# with this worker and the running status bound to it, reads
# unguarded-kind:id.
sub writes {
    my ( $self, $worker ) = @_;

    return [
        map { _write( $self->do_sql->[$_], $self->do_bind->[$_], $worker ) }
          0 .. $#{ $self->do_sql } ];
}

sub _write {
    my ( $sql, $bind, $worker ) = @_;

    my ( $assignments, $guard ) =
      $sql =~
      /\A UPDATE [ ] outbox_messages [ ] SET [ ] (.+?) [ ] (WHERE [ ] .+)/msx
      or return 'other';
    my @columns = map { /\A (\w+) [ ] = [ ] [?] \z/msx } split /,[ ]/msx,
      $assignments;
    my %value;
    @value{@columns} = @{$bind}[ 0 .. $#columns ];
    my ( $status, $owner, $id ) = reverse @{$bind};
    my $kind = "@columns" eq 'locked_until' ? 'renew' : $value{status};
    my $guarded =
         $guard eq $OWNED_GUARD
      && $owner eq $worker
      && $status eq 'running';

    return ( $guarded ? q{} : 'unguarded-' ) . ( $kind // 'other' ) . ":$id";
}

sub execute_statement {
    my ( $self, $sql, $attrs, @bind ) = @_;

    push @{ $self->do_sql },  $sql;
    push @{ $self->do_bind }, \@bind;

    return 1;
}

1;
