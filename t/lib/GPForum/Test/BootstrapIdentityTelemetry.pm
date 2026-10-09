# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::BootstrapIdentityTelemetry;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# Security telemetry that keeps every event it records, with its metadata.

has events => sub { return []; };

sub record {    ## no critic (NamingConventions::ProhibitAmbiguousNames) -- the security telemetry's own method name
    my ( $self, $event, $metadata ) = @_;

    push @{ $self->events },
      {
        event    => $event,
        metadata => $metadata,
      };

    return;
}

sub event_names {
    my ($self) = @_;

    return [ map { $_->{event} } @{ $self->events } ];
}

1;
