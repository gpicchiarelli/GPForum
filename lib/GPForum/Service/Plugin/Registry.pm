# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Plugin::Registry;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::X::Conflict;
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
const my @PLUGIN_COLUMNS => qw(
  author
  capabilities
  compatible_gpforum_range
  config_schema
  disabled_at
  enabled_at
  installed_at
  name
  plugin_id
  required_permissions
  status
  version
);

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
__PACKAGE__->requires(qw(schema));
has validator => sub {
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
# leaves hooks bound to a plugin that was never recorded, or the reverse. A
# plugin id that collides with another plugin's is drawn again, once; a row
# a concurrent install of the same manifest inserted first is reused.
sub _install_manifest ( $self, $manifest ) {
    my $existing = $self->_existing_plugin($manifest);
    return $self->_reuse_plugin( $existing, $manifest ) if $existing;

    my $plugin = $self->_plugin_row($manifest);
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_plugin_rows( $plugin, $manifest ); } );
    return _installed_hash( $created, 0 ) if $created;

    my $conflict = GPForum::X::Conflict->caught($error);
    if ( $conflict && $conflict->on($NAME_CONSTRAINT) ) {
        my $winner = $self->_existing_plugin($manifest);
        if ( !$winner ) {
            GPForum::Infrastructure::UniqueConflict->rethrow($error);
        }
        return $self->_reuse_plugin( $winner, $manifest );
    }
    if ( !$conflict || !$conflict->on($ID_CONSTRAINT) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $stored = _first_row( $self->schema->resultset('Plugin')
          ->search_rs( { plugin_id => $plugin->{plugin_id} }, { rows => 1 } ) );
    if ( _same_plugin( $stored, $manifest ) ) {
        return $self->_reuse_plugin( $stored, $manifest );
    }

    $plugin = { %{$plugin}, plugin_id => $self->id_service->uuid };
    ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_plugin_rows( $plugin, $manifest ); } );
    return _installed_hash( $created, 0 ) if $created;

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _reuse_plugin ( $self, $existing, $manifest ) {
    $self->_register_hooks( _column( $existing, 'plugin_id' ),
        $manifest->{hooks} );

    return _installed_hash( $existing, 1 );
}

sub _create_plugin_rows ( $self, $plugin, $manifest ) {
    $self->schema->resultset('Plugin')->create($plugin);
    $self->_register_hooks( $plugin->{plugin_id}, $manifest->{hooks} );

    return $plugin;
}

# The stored plugin is this manifest's: the same name and version.
sub _same_plugin ( $stored, $manifest ) {
    return 0 if !$stored;

    for my $field (qw(name version)) {
        my $held = _column( $stored, $field );
        return 0 if !defined $held || !defined $manifest->{$field};
        return 0 if $held ne $manifest->{$field};
    }

    return 1;
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
    return $search && $search->can('single') ? $search->single : undef;
}

sub _installed_hash ( $plugin, $skipped ) {
    return {
        ok     => 1,
        plugin => { map { $_ => _column( $plugin, $_ ) } @PLUGIN_COLUMNS },
        ( $skipped ? ( skipped => 1 ) : () ),
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
            my $plugin = $self->schema->resultset('Plugin')->find($plugin_id);
            if ( ( _column( $plugin, 'status' ) // q{} ) eq $status ) {
                return {
                    plugin_id => $plugin_id,
                    skipped   => 1,
                    status    => $status,
                };
            }

            my $now = $self->clock->now_iso8601;
            $plugin->update(
                $status eq $STATUS_ENABLED
                ? {
                    disabled_at => undef,
                    enabled_at  => $now,
                    status      => $status
                  }
                : { disabled_at => $now, status => $status }
            );

            return { plugin_id => $plugin_id, status => $status };
        }
    );
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

# A hook already bound is kept. A hook id that collides is drawn again, once;
# a hook a concurrent install bound first is kept.
sub _register_hooks ( $self, $plugin_id, $hooks ) {
    for my $hook ( @{$hooks} ) {
        my $row = $self->_hook_row( $plugin_id, $hook );
        if ( !$self->_existing_hook($row) ) {
            $self->_insert_hook($row);
        }
    }

    return;
}

sub _insert_hook ( $self, $row ) {
    my $insert = sub {
        $self->schema->resultset('PluginHook')->create($row);
        return $row;
    };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $insert );
    return $created if $created;

    my $conflict = GPForum::X::Conflict->caught($error);
    if (
        !$conflict
        || !(
               $conflict->on($HOOK_ID_CONSTRAINT)
            || $conflict->on($HOOK_NAME_CONSTRAINT)
        )
      )
    {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    my $existing = $self->_existing_hook($row);
    return $existing if $existing;
    if ( $conflict->on($HOOK_NAME_CONSTRAINT) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    $row->{hook_id} = $self->id_service->uuid;
    ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $insert );
    return $created if $created;

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
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
