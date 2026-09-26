# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PartitionDbh;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

has create_errors  => sub { return {}; };
has default_counts => sub { return {}; };
has probe_errors   => sub { return {}; };
has relations      => sub { return {}; };
has statements     => sub { return []; };

sub execute_statement {
    my ( $self, $sql, $attributes, @bind ) = @_;

    push @{ $self->statements }, { bind => \@bind, sql => $sql };
    my ($created) =
      $sql =~ /CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] (\w+)/msx;
    if ( defined $created ) {
        return $self->_create($created);
    }

    return 1;
}

sub selectrow_array {
    my ( $self, $sql, $attributes, @bind ) = @_;

    push @{ $self->statements }, { bind => \@bind, sql => $sql };
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

    my $error = $self->create_errors->{$name};
    croak $error if $error;
    $self->relations->{$name} = 1;

    return 1;
}

1;
