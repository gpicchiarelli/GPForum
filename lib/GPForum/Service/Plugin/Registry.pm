# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Plugin::Registry;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;

our $VERSION = '0.001';

const my $DEFAULT_HOOK_TIMEOUT_MS => 500;
const my $DEFAULT_HOOK_ORDER      => 100;
const my $STATUS_INSTALLED        => 'installed';
const my $STATUS_ENABLED          => 'enabled';
const my $STATUS_DISABLED         => 'disabled';
const my $ID_CONSTRAINT           => 'plugins_pkey';
const my $NAME_CONSTRAINT         => 'plugins_name_version_key';
const my $HOOK_ID_CONSTRAINT      => 'plugin_hooks_pkey';
const my $HOOK_NAME_CONSTRAINT    => 'idx_plugin_hooks_plugin_name_unique';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
has schema     => undef;
has validator  => sub {
    require GPForum::Service::Plugin::ManifestValidator;
    return GPForum::Service::Plugin::ManifestValidator->new;
};

sub install ( $self, $manifest ) {
    my $validation = $self->validator->validate($manifest);
    if ( !$validation->{ok} ) {
        return { ok => 0, errors => $validation->{errors} };
    }

    return $self->schema->txn_do(
        sub {
            return $self->_install_manifest($manifest);
        }
    );
}

# The plugin row and its hook rows are one installation: half a manifest
# leaves hooks bound to a plugin that was never recorded, or the reverse.
sub _install_manifest ( $self, $manifest ) {
    my $existing = $self->_existing_plugin($manifest);
    if ($existing) {
        return $self->_reuse_plugin( $existing, $manifest );
    }

    return $self->_insert_or_reuse_plugin($manifest);
}

sub _reuse_plugin ( $self, $existing, $manifest ) {
    $self->_register_hooks( _column( $existing, 'plugin_id' ),
        $manifest->{hooks} );

    return _installed_hash( $existing, 1 );
}

sub _insert_or_reuse_plugin ( $self, $manifest ) {
    my $ctx = {
        manifest => $manifest,
        plugin   => _plugin_row( $self, $manifest ),
    };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_plugin_rows($ctx); },
      );
    if ($created) {
        return _installed_hash( $created, 0 );
    }

    return $self->_plugin_after_conflict( $ctx, $error );
}

sub _plugin_after_conflict ( $self, $ctx, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_plugin_after_unique( $ctx, $error );
}

sub _plugin_after_unique ( $self, $ctx, $error ) {
    if ( _plugin_id_conflict($error) ) {
        return $self->_retry_or_reuse_plugin($ctx);
    }
    if ( _plugin_name_conflict($error) ) {
        return $self->_reuse_plugin_row( $ctx->{manifest}, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _retry_or_reuse_plugin ( $self, $ctx ) {
    my $stored = $self->_plugin_by_id( $ctx->{plugin}{plugin_id} );
    if ( $self->_same_open_plugin( $stored, $ctx->{manifest} ) ) {
        return $self->_reuse_plugin( $stored, $ctx->{manifest} );
    }

    return $self->_retry_plugin_id($ctx);
}

sub _same_open_plugin ( $self, $stored, $manifest ) {
    if ( !$stored ) {
        return 0;
    }
    if ( !_same_text( _column( $stored, 'name' ), $manifest->{name} ) ) {
        return 0;
    }

    return _same_text( _column( $stored, 'version' ), $manifest->{version} );
}

sub _retry_plugin_id ( $self, $ctx ) {
    $ctx->{plugin} =
      { %{ $ctx->{plugin} }, plugin_id => $self->id_service->uuid, };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_plugin_rows($ctx); },
      );
    if ($created) {
        return _installed_hash( $created, 0 );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _reuse_plugin_row ( $self, $manifest, $error ) {
    my $existing = $self->_existing_plugin($manifest);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_reuse_plugin( $existing, $manifest );
}

sub _plugin_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _plugin_name_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $NAME_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_plugin_rows ( $self, $ctx ) {
    my $plugin = $ctx->{plugin};
    $self->schema->resultset('Plugin')->create($plugin);
    $self->_register_hooks( $plugin->{plugin_id}, $ctx->{manifest}{hooks} );

    return $plugin;
}

sub _plugin_by_id ( $self, $plugin_id ) {
    my $search = $self->schema->resultset('Plugin')
      ->search_rs( { plugin_id => $plugin_id }, { rows => 1 }, );

    return _first_row($search);
}

sub _same_text ( $stored, $candidate ) {
    if ( !defined $stored || !defined $candidate ) {
        return 0;
    }

    return $stored eq $candidate ? 1 : 0;
}

sub _existing_plugin ( $self, $manifest ) {
    my $search = $self->schema->resultset('Plugin')->search_rs(
        {
            name    => $manifest->{name},
            version => $manifest->{version},
        },
        { rows => 1 },
    );

    return _first_row($search);
}

sub _first_row ($search) {
    if ( $search && $search->can('single') ) {
        return $search->single;
    }

    return;
}

sub _installed_hash ( $plugin, $skipped ) {
    my $result = {
        ok     => 1,
        plugin => _plugin_hash($plugin),
    };
    if ($skipped) {
        $result->{skipped} = 1;
    }

    return $result;
}

sub _plugin_hash ($plugin) {
    return {
        author                   => _column( $plugin, 'author' ),
        capabilities             => _column( $plugin, 'capabilities' ),
        compatible_gpforum_range =>
          _column( $plugin, 'compatible_gpforum_range' ),
        config_schema        => _column( $plugin, 'config_schema' ),
        disabled_at          => _column( $plugin, 'disabled_at' ),
        enabled_at           => _column( $plugin, 'enabled_at' ),
        installed_at         => _column( $plugin, 'installed_at' ),
        name                 => _column( $plugin, 'name' ),
        plugin_id            => _column( $plugin, 'plugin_id' ),
        required_permissions => _column( $plugin, 'required_permissions' ),
        status               => _column( $plugin, 'status' ),
        version              => _column( $plugin, 'version' ),
    };
}

sub enable ( $self, $plugin_id ) {
    return $self->_set_status( $plugin_id, $STATUS_ENABLED );
}

sub disable ( $self, $plugin_id ) {
    return $self->_set_status( $plugin_id, $STATUS_DISABLED );
}

sub _set_status ( $self, $plugin_id, $status ) {
    return $self->schema->txn_do(
        sub {
            return $self->_write_status( $plugin_id, $status );
        }
    );
}

sub _write_status ( $self, $plugin_id, $status ) {
    my $plugin = $self->schema->resultset('Plugin')->find($plugin_id);
    if ( _same_status( $plugin, $status ) ) {
        return _status_hash( $plugin_id, $status, 1 );
    }

    $plugin->update( $self->_status_changes($status) );

    return _status_hash( $plugin_id, $status, 0 );
}

sub _same_status ( $plugin, $status ) {
    if ( _text( _column( $plugin, 'status' ) ) ne $status ) {
        return 0;
    }

    return 1;
}

sub _status_changes ( $self, $status ) {
    if ( $status eq $STATUS_ENABLED ) {
        return {
            disabled_at => undef,
            enabled_at  => $self->clock->now_iso8601,
            status      => $status,
        };
    }

    return {
        disabled_at => $self->clock->now_iso8601,
        status      => $status,
    };
}

sub _status_hash ( $plugin_id, $status, $skipped ) {
    my $result = {
        plugin_id => $plugin_id,
        status    => $status,
    };
    if ($skipped) {
        $result->{skipped} = 1;
    }

    return $result;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

sub _text ($value) {
    if ( defined $value ) {
        return $value;
    }

    return q{};
}

sub _register_hooks ( $self, $plugin_id, $hooks ) {
    for my $hook ( @{$hooks} ) {
        $self->_record_hook( $plugin_id, $hook );
    }

    return;
}

sub _record_hook ( $self, $plugin_id, $hook ) {
    my $row = _hook_row( $self, $plugin_id, $hook );
    if ( $self->_existing_hook($row) ) {
        return;
    }

    return $self->_insert_or_reuse_hook($row);
}

sub _insert_or_reuse_hook ( $self, $row ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_hook($row); },
      );
    if ($created) {
        return $created;
    }

    return $self->_hook_after_conflict( $row, $error );
}

sub _hook_after_conflict ( $self, $row, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_hook_after_unique( $row, $error );
}

sub _hook_after_unique ( $self, $row, $error ) {
    if ( _hook_id_conflict($error) ) {
        return $self->_hook_after_id_conflict($row);
    }
    if ( _hook_name_conflict($error) ) {
        return $self->_reuse_hook_row( $row, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _hook_after_id_conflict ( $self, $row ) {
    my $existing = $self->_existing_hook($row);
    if ($existing) {
        return $existing;
    }

    return $self->_retry_hook_id($row);
}

sub _retry_hook_id ( $self, $row ) {
    $row->{hook_id} = $self->id_service->uuid;
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_hook($row); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _reuse_hook_row ( $self, $row, $error ) {
    my $existing = $self->_existing_hook($row);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $existing;
}

sub _hook_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $HOOK_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _hook_name_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $HOOK_NAME_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _insert_hook ( $self, $row ) {
    $self->schema->resultset('PluginHook')->create($row);

    return $row;
}

sub _existing_hook ( $self, $row ) {
    my $search = $self->schema->resultset('PluginHook')->search_rs(
        {
            hook_name => $row->{hook_name},
            plugin_id => $row->{plugin_id},
        },
        { rows => 1 },
    );

    return _first_row($search);
}

sub _plugin_row ( $self, $manifest ) {
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

sub _hook_row ( $self, $plugin_id, $hook ) {
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

__END__

=head1 NAME

GPForum::Service::Plugin::Registry - Install a plugin from its manifest and switch it on or off.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $registry = GPForum::Service::Plugin::Registry->new( schema => $schema );
    my $installed = $registry->install(
        {
            name                     => 'gpforum-analytics',
            version                  => '1.0.0',
            author                   => 'Giacomo Picchiarelli',
            compatible_gpforum_range => '>=0.1.0 <1.0.0',
            capabilities             => ['analytics_sink'],
            required_permissions     => ['analytics.write'],
            config_schema            => { sample_rate => 'number' },
            hooks                    => [
                {
                    hook_name     => 'post.created',
                    callback_name => 'analytics.record_post',
                },
            ],
        }
    );
    my $plugin_id = $installed->{plugin}{plugin_id};
    $registry->enable($plugin_id);
    $registry->disable($plugin_id);

=head1 DESCRIPTION

Records a plugin and the hooks it declares. A manifest is installed only
when L<GPForum::Service::Plugin::ManifestValidator> accepts it, and the
plugin row and its hook rows are written in one transaction, so a failed
install leaves neither hooks bound to a plugin that was never recorded nor
the reverse. A new plugin starts as C<installed>.

Installing is idempotent. A plugin is identified by its name and version
and a hook by its plugin and hook name, each backed by a unique index.
Installing a name and version that is already recorded reuses the plugin
row as it is and adds only the hooks it does not have yet; hooks already
recorded are not changed. Inserts run under savepoints through
L<GPForum::Infrastructure::UniqueConflict>, so a concurrent install of the
same manifest ends on the same rows, and a conflict on a generated id is
retried once with a fresh id.

Each hook takes its C<execution_order> (100), C<timeout_ms> (500),
C<side_effect_policy> (C<read_only>) and C<enabled> (1) from the manifest,
or the default in brackets when the manifest gives none.
L</enable> and L</disable> change the plugin row only; the hook rows keep
their own C<enabled> flag.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is required; C<clock>, C<id_service> and
C<validator> default to L<GPForum::Service::Clock>,
L<GPForum::Infrastructure::Id> and
L<GPForum::Service::Plugin::ManifestValidator>.

=head2 install

Takes a manifest hash reference (C<name>, C<version>, C<author>,
C<compatible_gpforum_range>, C<capabilities>, C<required_permissions>,
C<hooks>, and an optional C<config_schema>, an empty hash when absent).
When the manifest is invalid, returns C<< { ok => 0, errors => \%errors } >>
with the validator's errors and writes nothing. Otherwise returns
C<< { ok => 1, plugin => \%plugin } >> with the plugin's C<plugin_id>,
C<name>, C<version>, C<author>, C<compatible_gpforum_range>,
C<capabilities>, C<required_permissions>, C<config_schema>, C<status>,
C<installed_at>, C<enabled_at> and C<disabled_at>; C<< skipped => 1 >> is
added when the plugin was already installed.

=head2 enable

Takes a plugin id. In a transaction, sets the status to C<enabled>, stamps
C<enabled_at> and clears C<disabled_at>. Returns
C<< { plugin_id, status => 'enabled' } >>, with C<< skipped => 1 >> and no
write when the plugin was already enabled.

=head2 disable

Takes a plugin id. In a transaction, sets the status to C<disabled> and
stamps C<disabled_at>. Returns C<< { plugin_id, status => 'disabled' } >>,
with C<< skipped => 1 >> and no write when the plugin was already disabled.

=head1 DIAGNOSTICS

An invalid manifest is returned as errors, not thrown. Database errors
other than the handled unique conflicts are rethrown and the transaction
rolls back. C<enable> and C<disable> die when the plugin id matches no
plugin.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Plugin::ManifestValidator>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Infrastructure::Row>,
L<GPForum::Infrastructure::Id>, L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
