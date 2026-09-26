# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::DiscoveryController;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has last_content_type => undef;
has last_render       => undef;

sub res {
    my ($self) = @_;

    return $self;
}

sub headers {
    my ($self) = @_;

    return $self;
}

sub content_type {
    my ( $self, $type ) = @_;

    $self->last_content_type($type);

    return $self;
}

sub render {
    my ( $self, %args ) = @_;

    $self->last_render( \%args );

    return \%args;
}

1;
