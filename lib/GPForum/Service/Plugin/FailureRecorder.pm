package GPForum::Service::Plugin::FailureRecorder;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub record_failure {
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

1;
