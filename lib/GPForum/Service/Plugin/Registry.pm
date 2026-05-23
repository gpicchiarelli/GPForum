package GPForum::Service::Plugin::Registry;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $DEFAULT_HOOK_TIMEOUT_MS => 500;
const my $DEFAULT_HOOK_ORDER      => 100;
const my $STATUS_INSTALLED        => 'installed';
const my $STATUS_ENABLED          => 'enabled';
const my $STATUS_DISABLED         => 'disabled';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;
has validator  => sub {
    require GPForum::Service::Plugin::ManifestValidator;
    return GPForum::Service::Plugin::ManifestValidator->new;
};

sub install {
    my ( $self, $manifest ) = @_;

    my $validation = $self->validator->validate($manifest);
    return { ok => 0, errors => $validation->{errors} } if !$validation->{ok};

    my $plugin = _plugin_row( $self, $manifest );
    $self->schema->resultset('Plugin')->create($plugin);
    $self->_register_hooks( $plugin->{plugin_id}, $manifest->{hooks} );

    return { ok => 1, plugin => $plugin };
}

sub enable {
    my ( $self, $plugin_id ) = @_;

    my $plugin = $self->schema->resultset('Plugin')->find($plugin_id);
    $plugin->update(
        {
            status      => $STATUS_ENABLED,
            enabled_at  => $self->clock->now_iso8601,
            disabled_at => undef,
        }
    );

    return { plugin_id => $plugin_id, status => $STATUS_ENABLED };
}

sub disable {
    my ( $self, $plugin_id ) = @_;

    my $plugin = $self->schema->resultset('Plugin')->find($plugin_id);
    $plugin->update(
        {
            status      => $STATUS_DISABLED,
            disabled_at => $self->clock->now_iso8601,
        }
    );

    return { plugin_id => $plugin_id, status => $STATUS_DISABLED };
}

sub _register_hooks {
    my ( $self, $plugin_id, $hooks ) = @_;

    for my $hook ( @{$hooks} ) {
        my $row = _hook_row( $self, $plugin_id, $hook );
        $self->schema->resultset('PluginHook')->create($row);
    }

    return;
}

sub _plugin_row {
    my ( $self, $manifest ) = @_;

    return {
        plugin_id                => $self->id_service->uuid,
        name                     => $manifest->{name},
        version                  => $manifest->{version},
        author                   => $manifest->{author},
        compatible_gpforum_range => $manifest->{compatible_gpforum_range},
        status                   => $STATUS_INSTALLED,
        capabilities             => $manifest->{capabilities},
        required_permissions     => $manifest->{required_permissions},
        config_schema            => $manifest->{config_schema} || {},
        installed_at             => $self->clock->now_iso8601,
        enabled_at               => undef,
        disabled_at              => undef,
    };
}

sub _hook_row {
    my ( $self, $plugin_id, $hook ) = @_;

    return {
        hook_id         => $self->id_service->uuid,
        plugin_id       => $plugin_id,
        hook_name       => $hook->{hook_name},
        callback_name   => $hook->{callback_name},
        execution_order => $hook->{execution_order} || $DEFAULT_HOOK_ORDER,
        timeout_ms      => $hook->{timeout_ms}      || $DEFAULT_HOOK_TIMEOUT_MS,
        side_effect_policy => $hook->{side_effect_policy} || 'read_only',
        enabled            => exists $hook->{enabled} ? $hook->{enabled} : 1,
        created_at         => $self->clock->now_iso8601,
    };
}

1;
