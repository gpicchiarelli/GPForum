# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxBenchmarkDbh;

use Const::Fast;
use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# Where in the binds of a write after the claim the message's id is: third
# from last, before the worker and the running status.
const my $MESSAGE_ID => -3;

has cursor         => 0;
has do_bind        => sub { return []; };
has do_sql         => sub { return []; };
has outcome_writes => 0;
has rows           => sub { return []; };

# DBI keeps the driver on the handle, where code reads $dbh->{Driver}{Name}.
sub new {
    my ( $class, @attributes ) = @_;

    my $self = $class->SUPER::new(@attributes);
    $self->{Driver} //= { Name => 'Pg' };

    return $self;
}

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

# The dispatcher's writes after the claim are UPDATE ... RETURNING on one
# message, read rather than executed blind. Reporting its id back models the
# ordinary case where the message is still this worker's.
sub selectcol_arrayref {
    my ( $self, $sql, $attrs, @bind ) = @_;

    push @{ $self->do_sql },  $sql;
    push @{ $self->do_bind }, \@bind;
    if ( _sets_status($sql) ) {
        $self->outcome_writes( $self->outcome_writes + 1 );
    }

    return [ $bind[$MESSAGE_ID] ];
}

sub do {    ## no critic (Subroutines::ProhibitBuiltinHomonyms) -- DBI's method
    my ( $self, $sql, $attrs, @bind ) = @_;

    push @{ $self->do_sql },  $sql;
    push @{ $self->do_bind }, \@bind;
    if ( _sets_status($sql) ) {
        $self->outcome_writes( $self->outcome_writes + 1 );
    }

    return 1;
}

# An outbox UPDATE that writes the status -- an acknowledgement or a
# failure, one a message -- and not a claim renewal, which writes
# locked_until alone. outcome_writes counts the first kind.
sub _sets_status {
    my ($sql) = @_;

    my ($assignments) = split /[ ]WHERE[ ]/msx, $sql, 2;

    return $assignments =~
      /\A UPDATE [ ] outbox_messages [ ] SET [ ] .* \b status [ ] = /msx
      ? 1
      : 0;
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
