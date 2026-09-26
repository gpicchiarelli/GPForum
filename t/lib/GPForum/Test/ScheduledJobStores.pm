# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ScheduledJobStores;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has attachment_calls => sub { return []; };
has calls            => sub { return []; };
has orphan_result    => sub {
    return { deleted => [ { attachment_id => 'att-1' } ], ok => 1 };
};

sub purge_sessions {
    my ( $self, $input ) = @_;

    return $self->_record( 'sessions', $input );
}

sub purge_identity_tokens {
    my ( $self, $input ) = @_;

    return $self->_record( 'identity_tokens', $input );
}

sub purge_rate_limit_buckets {
    my ( $self, $input ) = @_;

    return $self->_record( 'rate_limit_buckets', $input );
}

sub purge_outbox_messages {
    my ( $self, $input ) = @_;

    return $self->_record( 'outbox_messages', $input );
}

sub purge_dead_letters {
    my ( $self, $input ) = @_;

    return $self->_record( 'dead_letters', $input );
}

sub cleanup_orphans {
    my ( $self, $input ) = @_;

    push @{ $self->attachment_calls }, $input;

    return $self->orphan_result;
}

sub _record {
    my ( $self, $job, $input ) = @_;

    push @{ $self->calls }, { input => $input, job => $job };

    return {
        deleted => 1,
        limit   => $input->{limit},
        ok      => 1,
    };
}

1;
