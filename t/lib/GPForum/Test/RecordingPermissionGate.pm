# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RecordingPermissionGate;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

has last_permission => sub { return {}; };

sub allowed {
    my ( $self, undef, $permission ) = @_;

    $self->last_permission($permission);

    return 1;
}

1;
