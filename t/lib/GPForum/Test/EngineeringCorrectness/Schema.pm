# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::EngineeringCorrectness::Schema;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;
use Try::Tiny;

use GPForum::Test::EngineeringCorrectness::ResultSet;

our $VERSION = '0.001';

has created               => sub { return {}; };
has fail_resultset        => undef;
has post_positions        => sub { return {}; };
has transactions          => 0;
has unique_post_positions => 0;

sub resultset {
    my ( $self, $name ) = @_;

    return GPForum::Test::EngineeringCorrectness::ResultSet->new(
        name   => $name,
        schema => $self,
    );
}

sub txn_do {
    my ( $self, $code ) = @_;

    my $snapshot          = $self->_clone_created;
    my $position_snapshot = { %{ $self->post_positions } };
    $self->transactions( $self->transactions + 1 );

    my $result;
    my $failure;
    try {
        $result = $code->();
    }
    catch {
        $failure = $_;
    };
    if ($failure) {
        $self->created($snapshot);
        $self->post_positions($position_snapshot);
        croak $failure;
    }

    return $result;
}

sub _clone_created {
    my ($self) = @_;

    my %clone;
    for my $name ( keys %{ $self->created } ) {
        $clone{$name} =
          [ map { _copied_row($_) } @{ $self->created->{$name} } ];
    }

    return \%clone;
}

sub created_for {
    my ( $self, $name ) = @_;

    $self->created->{$name} ||= [];

    return $self->created->{$name};
}

sub _copied_row {
    my ($row) = @_;

    return { %{$row} };
}

1;
