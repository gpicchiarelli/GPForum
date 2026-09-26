# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::Workflow;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my %ALLOWED_VISIBILITY => (
    members => 1,
    private => 1,
    public  => 1,
);

has binding_store       => undef;
has category_store      => undef;
has command_idempotency => undef;
has dead_letter_replay  => undef;
has logger              => undef;
has maintenance         => undef;
has role_catalog        => undef;

sub create_role ( $self, $input ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    return $self->_create_named_role($input);
}

sub create_permission ( $self, $input ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    return $self->_create_named_permission($input);
}

sub attach_permission ( $self, $input ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    return $self->_attach_named_permission($input);
}

sub bind_role ( $self, $input ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    return $self->_bind_named_role($input);
}

sub revoke_binding ( $self, $input ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    return $self->_revoke_named_binding($input);
}

sub create_category ( $self, $input ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    return $self->_create_named_category($input);
}

sub update_category ( $self, $input ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    return $self->_update_named_category($input);
}

# Replays a dead letter under the command's idempotency, so a lost response
# retried with the same command id gets the first answer back instead of a
# conflict from the replay the first attempt already made.
sub replay_dead_letter ( $self, $input ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    my $dead_letter_id = _trim( $input->{dead_letter_id} );
    return $self->_commanded_write(
        {
            actor_id     => $input->{actor_user_id},
            command_id   => $input->{command_id},
            command_type => 'admin.dead_letter_replay',
            request      => {
                actor_user_id  => $input->{actor_user_id},
                dead_letter_id => $dead_letter_id,
            },
            run => sub {
                return $self->_run_replay(
                    {
                        actor_user_id  => $input->{actor_user_id},
                        dead_letter_id => $dead_letter_id,
                        via            => 'web',
                    }
                );
            },
        }
    );
}

# 6.5: a search rebuild through the outbox, and a purge of the public page
# cache, each under a command id and audited (Admin::Maintenance).
sub request_search_rebuild ( $self, $input ) {
    return $self->_maintenance_command( $input, 'admin.search_rebuild',
        sub { return $self->maintenance->request_search_rebuild($input); } );
}

sub purge_public_cache ( $self, $input ) {
    return $self->_maintenance_command( $input, 'admin.cache_purge',
        sub { return $self->maintenance->purge_public_cache($input); } );
}

sub _maintenance_command ( $self, $input, $command_type, $work ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_write(
        {
            actor_id     => $input->{actor_user_id},
            command_id   => $input->{command_id},
            command_type => $command_type,
            request      => { actor_user_id => $input->{actor_user_id} },
            run          => sub {
                my $stored = $self->_eval_store($work);
                return _failed_result() if $stored->{failed};

                return _result( status => 'ok', stored => $stored->{value} );
            },
        }
    );
}

sub _run_replay ( $self, $request ) {
    my $stored = $self->_eval_store(
        sub { return $self->dead_letter_replay->replay($request); } );
    if ( $stored->{failed} ) {
        return _failed_result();
    }

    my $outcome = $stored->{value};
    if ( $outcome->{status} ne 'replayed' ) {
        return _result(
            error  => $outcome->{error},
            status => $outcome->{status},
        );
    }

    return _result(
        status => 'ok',
        stored => $outcome->{replayed},
    );
}

sub _create_named_role ( $self, $input ) {
    my $command = {
        actor_user_id => $input->{actor_user_id},
        description   => _optional( $input->{description} ),
        name          => _trim( $input->{name} ),
    };
    my $invalid = $self->_missing_fields( $command, ['name'] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_store(
        {
            actor_id     => $input->{actor_user_id},
            command_id   => $input->{command_id},
            command_type => 'admin.role_create',
            not_found    => 'role not found',
            request      => {
                actor_user_id => $command->{actor_user_id},
                description   => $command->{description},
                name          => $command->{name},
            },
            run => sub { return $self->role_catalog->create_role($command); },
        }
    );
}

sub _create_named_permission ( $self, $input ) {
    my $command = {
        action        => _trim( $input->{action} ),
        actor_user_id => $input->{actor_user_id},
        name          => _trim( $input->{name} ),
        resource_type => _trim( $input->{resource_type} ),
    };
    my $invalid =
      $self->_missing_fields( $command, [qw(name resource_type action)] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_store(
        {
            actor_id     => $input->{actor_user_id},
            command_id   => $input->{command_id},
            command_type => 'admin.permission_create',
            not_found    => 'permission not found',
            request      => {
                action        => $command->{action},
                actor_user_id => $command->{actor_user_id},
                name          => $command->{name},
                resource_type => $command->{resource_type},
            },
            run =>
              sub { return $self->role_catalog->create_permission($command); },
        }
    );
}

sub _attach_named_permission ( $self, $input ) {
    my $command = {
        actor_user_id => $input->{actor_user_id},
        permission_id => _trim( $input->{permission_id} ),
        role_id       => _trim( $input->{role_id} ),
    };
    my $invalid =
      $self->_missing_fields( $command, [qw(role_id permission_id)] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_store(
        {
            actor_id     => $input->{actor_user_id},
            command_id   => $input->{command_id},
            command_type => 'admin.permission_attach',
            not_found    => 'role permission not found',
            request      => {
                actor_user_id => $command->{actor_user_id},
                permission_id => $command->{permission_id},
                role_id       => $command->{role_id},
            },
            run =>
              sub { return $self->role_catalog->attach_permission($command); },
        }
    );
}

sub _bind_named_role ( $self, $input ) {
    my $command = {
        actor_user_id => $input->{actor_user_id},
        resource_id   => _optional( $input->{resource_id} ),
        resource_type => _trim( $input->{resource_type} ),
        role_id       => _trim( $input->{role_id} ),
        space_id      => _optional( $input->{space_id} ),
        user_id       => _trim( $input->{user_id} ),
    };
    my $invalid =
      $self->_missing_fields( $command, [qw(user_id role_id resource_type)] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_store(
        {
            actor_id     => $input->{actor_user_id},
            command_id   => $input->{command_id},
            command_type => 'admin.role_bind',
            not_found    => 'role binding not found',
            request      => {
                actor_user_id => $command->{actor_user_id},
                resource_id   => $command->{resource_id},
                resource_type => $command->{resource_type},
                role_id       => $command->{role_id},
                space_id      => $command->{space_id},
                user_id       => $command->{user_id},
            },
            run => sub { return $self->binding_store->bind_role($command); },
        }
    );
}

sub _revoke_named_binding ( $self, $input ) {
    return $self->_commanded_store(
        {
            actor_id     => $input->{actor_user_id},
            command_id   => $input->{command_id},
            command_type => 'admin.binding_revoke',
            not_found    => 'role binding not found',
            request      => {
                actor_user_id => $input->{actor_user_id},
                binding_id    => _trim( $input->{binding_id} ),
            },
            run => sub {
                return $self->binding_store->revoke_binding(
                    $input->{binding_id}, $input->{actor_user_id} );
            },
        }
    );
}

sub _create_named_category ( $self, $input ) {
    my $command = $self->_category_command($input);
    my $invalid = $self->_invalid_category( $command, ['title'] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_store(
        {
            actor_id     => $input->{actor_user_id},
            command_id   => $input->{command_id},
            command_type => 'admin.category_create',
            not_found    => 'space not found',
            request      => _category_request($command),
            run          =>
              sub { return $self->category_store->create_category($command); },
        }
    );
}

sub _update_named_category ( $self, $input ) {
    my $command = $self->_category_command($input);
    my $invalid = $self->_invalid_category( $command, ['category_id'] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_store(
        {
            actor_id     => $input->{actor_user_id},
            command_id   => $input->{command_id},
            command_type => 'admin.category_update',
            not_found    => 'category not found',
            request      => _category_request($command),
            run          =>
              sub { return $self->category_store->update_category($command); },
        }
    );
}

sub _category_request ($command) {
    return {
        actor_user_id => $command->{actor_user_id},
        category_id   => $command->{category_id},
        description   => $command->{description},
        position      => $command->{position},
        slug          => $command->{slug},
        space_id      => $command->{space_id},
        title         => $command->{title},
        visibility    => $command->{visibility},
    };
}

sub _category_command ( $, $input ) {
    return {
        actor_user_id => $input->{actor_user_id},
        category_id   => _trim( $input->{category_id} ),
        description   => _optional( $input->{description} ),
        position      => _optional( $input->{position} ),
        slug          => _optional( $input->{slug} ),
        space_id      => _optional( $input->{space_id} ),
        title         => _trim( $input->{title} ),
        visibility    => _optional( $input->{visibility} ),
    };
}

sub _invalid_category ( $self, $command, $required ) {
    my $missing = $self->_missing_fields( $command, $required );
    if ($missing) {
        return $missing;
    }

    return $self->_invalid_visibility($command);
}

sub _invalid_visibility ( $, $command ) {
    if ( _visibility_ok( $command->{visibility} ) ) {
        my $undefined;
        return $undefined;
    }

    return _result(
        status => 'invalid',
        errors => { visibility => 'visibility is invalid' },
    );
}

sub _visibility_ok ($value) {
    my $trimmed = _trim($value);
    if ( !length $trimmed ) {
        return 1;
    }

    if ( exists $ALLOWED_VISIBILITY{$trimmed} ) {
        return 1;
    }

    return 0;
}

sub _commanded_store ( $self, $job ) {
    return $self->_commanded_write(
        {
            actor_id     => $job->{actor_id},
            command_id   => $job->{command_id},
            command_type => $job->{command_type},
            request      => $job->{request} || {},
            run          => sub {
                return $self->_run_store( $job->{not_found}, $job->{run} );
            },
        }
    );
}

sub _commanded_write ( $self, $job ) {
    if ( !$self->command_idempotency ) {
        return $job->{run}->();
    }

    return $self->_idempotent_write($job);
}

sub _idempotent_write ( $self, $job ) {
    my $result = eval { return $self->command_idempotency->result_of($job); };
    if ($EVAL_ERROR) {
        $self->_log_error("admin write failed: $EVAL_ERROR");
        return _failed_result();
    }

    return $result;
}

sub _missing_command_id ( $, $input ) {
    if ( length _trim( $input->{command_id} ) ) {
        my $undefined;
        return $undefined;
    }

    return _result(
        errors => { command_id => 'command_id is required' },
        status => 'invalid',
    );
}

sub _failed_result {
    return _result(
        error  => 'admin store failed',
        status => 'failed',
    );
}

sub _missing_fields ( $, $input, $names ) {
    my %errors;
    for my $name ( @{$names} ) {
        if ( !length _trim( $input->{$name} ) ) {
            $errors{$name} = "$name is required";
        }
    }
    if (%errors) {
        return _result(
            status => 'invalid',
            errors => \%errors,
        );
    }

    my $undefined;
    return $undefined;
}

sub _run_store ( $self, $not_found, $code ) {
    my $stored = $self->_eval_store($code);
    if ( $stored->{failed} ) {
        return _failed_result();
    }
    if ( !$stored->{value} ) {
        return _result(
            status => 'not_found',
            error  => $not_found,
        );
    }

    return _result(
        status => 'ok',
        stored => $stored->{value},
    );
}

# Under a command id the store runs inside the command's transaction, and its
# exception has to reach that transaction: caught here, the transaction went
# on to commit whatever the store wrote before it failed -- a replay's outbox
# message without its audit row -- and stored "failed" as the command's
# answer, so retrying the same command could never succeed.
# _idempotent_write catches it instead, after the rollback.
sub _eval_store ( $self, $code ) {
    return { value => $code->() } if $self->command_idempotency;

    my $value = eval { return $code->(); };
    if ($EVAL_ERROR) {
        $self->_log_error("admin write failed: $EVAL_ERROR");
        return { failed => 1 };
    }

    return { value => $value };
}

sub _result (%input) {
    return {
        error  => $input{error},
        errors => $input{errors},
        ok     => ( $input{status} || q{} ) eq 'ok' ? 1 : 0,
        status => $input{status} || 'failed',
        stored => $input{stored},
    };
}

sub _optional ($value) {
    my $trimmed = _trim($value);
    return length $trimmed ? $trimmed : undef;
}

sub _trim ($value) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _log_error ( $self, $message ) {
    if ( !$self->logger || !$self->logger->can('error') ) {
        return;
    }

    $self->logger->error($message);

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Admin::Workflow - Admin authorization write commands.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = $workflow->create_role(
        {
            actor_user_id => $user_id,
            command_id    => $command_id,
            name          => $name,
        }
    );

=head1 DESCRIPTION

Application boundary for admin catalog, role-binding, and category writes.
Validates required command fields, requires HTTP C<command_id>, delegates
persistence to C<RoleCatalog>, C<RoleBindingStore>, and C<CategoryStore>,
and returns a normalized result hash. Replays from C<command_log> when the
helper is present. Command hashes include actor and target fields only.
Stores keep transaction, event, audit, and outbox ownership.

=head1 SUBROUTINES/METHODS

=head2 create_role

Creates a role when a name is present.

=head2 create_permission

Creates a permission when name, resource type, and action are present.

=head2 attach_permission

Attaches a permission to a role.

=head2 bind_role

Binds a role to a user for a resource type.

=head2 revoke_binding

Revokes an existing role binding.

=head2 create_category

Creates a category when a title is present.

=head2 update_category

Updates a category when a category id is present.

=head2 replay_dead_letter

Replays a dead letter through L<GPForum::Service::Outbox::DeadLetterReplay>,
under the command id. C<not_found> when there is no such dead letter,
C<conflict> when it cannot be replayed.

=head1 DIAGNOSTICS

Returns C<invalid>, C<not_found>, C<conflict>, or C<failed> statuses instead of
throwing for expected write outcomes. Unexpected store exceptions are logged
and mapped to C<failed>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses role catalog, binding, and category stores plus the command-idempotency
helper supplied by the composition root.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Stores keep name/scope uniqueness. HTTP retries with the same C<command_id>
replay from C<command_log>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
