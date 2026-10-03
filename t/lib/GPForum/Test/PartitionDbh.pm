# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PartitionDbh;

use Carp qw(croak);
use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# create_errors fail the ATTACH of the named partition, where PostgreSQL
# raises a DEFAULT overlap or a lock timeout; the CREATE before it succeeds
# and is rolled back with it. An error given as a list fails one attempt per
# entry, and the attempts after them succeed. lock_held says another run
# holds the maintenance advisory lock: trying it says no, and waiting for it
# times out. A partition created inside a transaction exists only once it
# commits.
has create_errors  => sub { return {}; };
has default_counts => sub { return {}; };
has lock_held      => 0;
has pending        => sub { return {}; };
has probe_errors   => sub { return {}; };
has relations      => sub { return {}; };
has statements     => sub { return []; };
has transactions   => sub { return []; };

sub begin_work {
    my ($self) = @_;

    croak 'Already in a transaction' if $self->{in_transaction};
    $self->{in_transaction} = 1;
    $self->pending( {} );
    push @{ $self->transactions }, 'begin';

    return 1;
}

sub commit {
    my ($self) = @_;

    croak 'commit without a transaction' if !$self->{in_transaction};
    $self->{in_transaction} = 0;
    for my $name ( keys %{ $self->pending } ) {
        $self->relations->{$name} = 1;
    }
    $self->pending( {} );
    push @{ $self->transactions }, 'commit';

    return 1;
}

sub rollback {
    my ($self) = @_;

    $self->{in_transaction} = 0;
    $self->pending( {} );
    push @{ $self->transactions }, 'rollback';

    return 1;
}

sub execute_statement {
    my ( $self, $sql, $attributes, @bind ) = @_;

    push @{ $self->statements }, { bind => \@bind, sql => $sql };
    my ($created) = $sql =~ /\A CREATE [ ] TABLE [ ] (\w+) [ ] [(]LIKE/msx;
    if ( defined $created ) {
        return $self->_create($created);
    }
    my ($attached) = $sql =~ /ATTACH [ ] PARTITION [ ] (\w+) [ ] FOR/msx;
    if ( defined $attached ) {
        return $self->_attach($attached);
    }

    return 1;
}

sub selectrow_array {
    my ( $self, $sql, $attributes, @bind ) = @_;

    push @{ $self->statements }, { bind => \@bind, sql => $sql };
    if ( $sql =~ /pg_try_advisory_lock/msx ) {
        return $self->lock_held ? 0 : 1;
    }
    if ( $sql =~ /pg_advisory_lock/msx ) {
        croak 'DBD::Pg::db selectrow_array failed: ERROR:  canceling'
          . ' statement due to lock timeout'
          if $self->lock_held;
        return 1;
    }
    if ( $sql =~ /pg_advisory_unlock/msx ) {
        return 1;
    }
    if ( $sql =~ /to_regclass/msx ) {
        my $missing;
        return $self->relations->{ $bind[0] } ? $bind[0] : $missing;
    }
    my ($table) = $sql =~ /FROM [ ] (\w+)/msx;
    my $failure = $self->probe_errors->{ $table || q{} };
    croak $failure if $failure;

    return $self->default_counts->{ $table || q{} } || 0;
}

sub statements_like {
    my ( $self, $pattern ) = @_;

    return [ grep { $_->{sql} =~ $pattern } @{ $self->statements } ];
}

sub _create {
    my ( $self, $name ) = @_;

    croak "relation \"$name\" already exists" if $self->relations->{$name};
    $self->pending->{$name} = 1;

    return 1;
}

sub _attach {
    my ( $self, $name ) = @_;

    my $error = $self->create_errors->{$name};
    if ( ref $error eq 'ARRAY' ) {
        $error = shift @{$error};
    }
    croak $error if $error;

    return 1;
}

1;
