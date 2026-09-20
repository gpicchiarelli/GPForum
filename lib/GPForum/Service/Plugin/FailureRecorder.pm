package GPForum::Service::Plugin::FailureRecorder;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $ID_CONSTRAINT => 'plugin_failures_pkey';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub record_failure {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_insert_failure($input); };
    if ($created) {
        return $created;
    }

    return $self->_failure_after_conflict( $input, $EVAL_ERROR );
}

sub _insert_failure {
    my ( $self, $input ) = @_;

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

sub _failure_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( index( $error, $ID_CONSTRAINT ) < 0 ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_failure_id($input);
}

sub _retry_failure_id {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_insert_failure($input); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

1;
