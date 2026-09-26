# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Plugin::FailureRecorder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;

our $VERSION = '0.001';

const my $ID_CONSTRAINT => 'plugin_failures_pkey';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
has schema     => undef;

sub record_failure ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_failure($input); },
      );
    if ($created) {
        return $created;
    }

    return $self->_failure_after_conflict( $input, $error );
}

sub _insert_failure ( $self, $input ) {
    my $failure = {
        plugin_failure_id => $self->id_service->uuid,
        plugin_id         => $input->{plugin_id},
        hook_name         => $input->{hook_name},
        error_class       => $input->{error_class},
        error_message     => $input->{error_message},
        context           => $input->{context} || {},
        created_at        => $self->clock->now_iso8601,
    };
    $self->schema->resultset('PluginFailure')->create($failure);

    return $failure;
}

sub _failure_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( index( $error, $ID_CONSTRAINT ) < 0 ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_failure_id($input);
}

sub _retry_failure_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_failure($input); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

1;
