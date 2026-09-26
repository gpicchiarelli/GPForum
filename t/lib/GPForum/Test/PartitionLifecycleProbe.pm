# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PartitionLifecycleProbe;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls => sub { return []; };

sub policy_version {
    return 1;
}

sub plan_window {
    my ( $self, $input ) = @_;

    $self->_record( 'plan_window', $input );

    return [
        {
            partition_name => 'event_log_2026_09',
            state          => 'planned',
        }
    ];
}

sub retention_due {
    my ( $self, $input ) = @_;

    $self->_record( 'retention_due', $input );

    return [ { recommended_state => 'detached' } ];
}

sub restore_evidence {
    my ( $self, $input ) = @_;

    $self->_record( 'restore_evidence', $input );

    return {
        ok             => 1,
        policy_version => 1,
        restore_ready  => 0,
    };
}

sub _record {
    my ( $self, $method, $input ) = @_;

    push @{ $self->calls }, { input => $input, method => $method };

    return;
}

1;
