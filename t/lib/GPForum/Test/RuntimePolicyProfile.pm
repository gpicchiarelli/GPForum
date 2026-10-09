# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RuntimePolicyProfile;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# An OS profile whose socket and feature snapshots are the ones it was given,
# so OS::RuntimePolicy can be read against a host chosen by the test. The
# settings each snapshot was asked with are kept.

has cpu_count => 1;
has sockets   => sub { return {}; };
has features  => sub { return {}; };
has asked     => sub { return []; };

sub socket_snapshot ( $self, $settings ) {
    push @{ $self->asked }, $settings;

    return $self->sockets;
}

sub feature_snapshot ( $self, $settings ) {
    push @{ $self->asked }, $settings;

    return $self->features;
}

1;
