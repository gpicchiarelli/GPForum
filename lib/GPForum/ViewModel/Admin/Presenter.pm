# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::ViewModel::Admin::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base', -signatures;
use Mojo::JSON qw(encode_json);

our $VERSION = '0.001';

sub dashboard ( $self, %input ) {
    return {
        audit_rows =>
          [ map { $self->audit_entry($_) } @{ $input{audit_rows} || [] } ],
        csrf_token => $input{csrf_token},
        roles      => [ map { $self->role($_) } @{ $input{roles} || [] } ],
        summary    => $input{summary} || {},
    };
}

sub roles_page ( $self, %input ) {
    return {
        csrf_token            => $input{csrf_token},
        permission_command_id => $self->string( $input{permission_command_id} ),
        permissions           =>
          [ map { $self->permission($_) } @{ $input{permissions} || [] } ],
        role_command_id => $self->string( $input{role_command_id} ),
        roles           => $self->_roles_with_attach( \%input ),
    };
}

sub categories_page ( $self, %input ) {
    return {
        categories        => $self->_categories_with_update( \%input ),
        create_command_id => $self->string( $input{create_command_id} ),
        csrf_token        => $input{csrf_token},
    };
}

sub user_roles_page ( $self, %input ) {
    return {
        bind_command_id => $self->string( $input{bind_command_id} ),
        bindings        => $self->_bindings_with_revoke( \%input ),
        csrf_token      => $input{csrf_token},
        user_id         => $input{user_id},
    };
}

sub users_page ( $self, %input ) {
    return {
        status => $input{status},
        users  => [ map { $self->user($_) } @{ $input{users} || [] } ],
    };
}

sub jobs_page ( $self, %input ) {
    my $jobs = $input{jobs} || {};
    my $ids  = $input{replay_command_ids};
    if ( ref $ids ne 'HASH' ) {
        $ids = {};
    }

    return {
        jobs => {
            dead_letters => [
                map { $self->_dead_letter_with_replay( $_, $ids ) }
                  @{ $jobs->{dead_letters} || [] }
            ],
            outbox_messages => [
                map { $self->outbox_message($_) }
                  @{ $jobs->{outbox_messages} || [] }
            ],
        },
        maintenance => $input{maintenance} || {},
        status      => $input{status},
    };
}

sub status_page ( $self, %input ) {
    my $status    = $input{admin_status}                || {};
    my $endpoints = $status->{query_budgets}{endpoints} || {};

    return {
        admin_status       => $status,
        benchmark          => $status->{benchmark}          || {},
        metrics            => $status->{metrics}            || {},
        query_budget_drift => $status->{query_budget_drift} || {},
        query_budget_rows  => [
            map {
                {
                    endpoint    => $_,
                    max_queries => $endpoints->{$_}{max_queries},
                    ui          => {
                        row_id => $self->stable_id( 'query-budget', $_ ),
                    },
                }
            } sort keys %{$endpoints}
        ],
        readiness => $status->{readiness} || {},
    };
}

sub audit_page ( $self, %input ) {
    my $filters = $input{filters} || {};
    my $errors  = $input{errors}  || {};

    return {
        audit_rows =>
          [ map { $self->audit_entry($_) } @{ $input{audit_rows} || [] } ],
        filters => $filters,
        invalid => [
            map { { field => $_, value => $errors->{$_} } }
            sort keys %{$errors}
        ],
        next_cursor => $input{next_cursor},

        # What the form shows: every value submitted, valid or not, so an
        # operator can correct a typo rather than retype the whole query.
        submitted   => { %{$filters}, %{$errors} },
        target_id   => $filters->{target_id},
        target_type => $filters->{target_type},
    };
}

sub role_response ( $self, $status, $role ) {
    return {
        role   => $self->role($role),
        status => $status,
    };
}

sub permission_response ( $self, $status, $permission ) {
    return {
        permission => $self->permission($permission),
        status     => $status,
    };
}

sub role_permission_response ( $self, $status, $role_permission ) {
    return {
        role_permission => $self->role_permission($role_permission),
        status          => $status,
    };
}

sub role_binding_response ( $self, $status, $binding ) {
    return {
        binding => $self->role_binding($binding),
        status  => $status,
    };
}

sub category_response ( $self, $status, $category ) {
    return {
        category => $self->category($category),
        status   => $status,
    };
}

sub _roles_with_attach ( $self, $input ) {
    my $ids = $input->{attach_command_ids};
    if ( ref $ids ne 'HASH' ) {
        $ids = {};
    }

    return [ map { $self->_role_with_command( $_, $ids ) }
          @{ $input->{roles} || [] } ];
}

sub _role_with_command ( $self, $row, $ids ) {
    my $role    = $self->role($row);
    my $role_id = $role->{role_id} || q{};
    $role->{attach_command_id} = $self->string( $ids->{$role_id} );

    return $role;
}

sub _categories_with_update ( $self, $input ) {
    my $ids = $input->{update_command_ids};
    if ( ref $ids ne 'HASH' ) {
        $ids = {};
    }

    return [ map { $self->_category_with_command( $_, $ids ) }
          @{ $input->{categories} || [] } ];
}

sub _category_with_command ( $self, $row, $ids ) {
    my $category    = $self->category($row);
    my $category_id = $category->{category_id} || q{};
    $category->{update_command_id} = $self->string( $ids->{$category_id} );

    return $category;
}

sub _bindings_with_revoke ( $self, $input ) {
    my $ids = $input->{revoke_command_ids};
    if ( ref $ids ne 'HASH' ) {
        $ids = {};
    }

    return [ map { $self->_binding_with_command( $_, $ids ) }
          @{ $input->{bindings} || [] } ];
}

sub _binding_with_command ( $self, $row, $ids ) {
    my $binding    = $self->role_binding($row);
    my $binding_id = $binding->{binding_id} || q{};
    $binding->{revoke_command_id} = $self->string( $ids->{$binding_id} );

    return $binding;
}

sub user ( $self, $row ) {
    my $user_id = $self->column( $row, 'id' )
      || $self->column( $row, 'user_id' );

    return {
        created_at        => $self->column( $row, 'created_at' ),
        deleted_at        => $self->column( $row, 'deleted_at' ),
        display_name      => $self->column( $row, 'display_name' ),
        email_normalized  => $self->column( $row, 'email_normalized' ),
        email_verified_at => $self->column( $row, 'email_verified_at' ),
        id                => $user_id,
        status            => $self->column( $row, 'status' ),
        trust_level       => $self->column( $row, 'trust_level' ),
        ui                => {
            audit_link_target_type => 'user',
            heading_id => $self->stable_id( 'admin-user', $user_id, 'heading' ),
        },
        updated_at => $self->column( $row, 'updated_at' ),
        user_id    => $user_id,
        username   => $self->column( $row, 'username' ),
    };
}

sub category ( $self, $row ) {
    my $category_id = $self->column( $row, 'category_id' );

    return {
        category_id => $category_id,
        created_at  => $self->column( $row, 'created_at' ),
        description => $self->column( $row, 'description' ),
        position    => $self->column( $row, 'position' ),
        slug        => $self->column( $row, 'slug' ),
        space_id    => $self->column( $row, 'space_id' ),
        title       => $self->column( $row, 'title' ),
        ui          => {
            heading_id =>
              $self->stable_id( 'category', $category_id, 'heading' ),
        },
        updated_at => $self->column( $row, 'updated_at' ),
        visibility => $self->column( $row, 'visibility' ),
    };
}

sub role ( $self, $row ) {
    my $role_id = $self->column( $row, 'role_id' );

    return {
        created_at  => $self->column( $row, 'created_at' ),
        description => $self->column( $row, 'description' ),
        name        => $self->column( $row, 'name' ),
        role_id     => $role_id,
        ui          => {
            heading_id => 'role-' . $self->string($role_id) . '-heading',
        },
    };
}

sub permission ( $self, $row ) {
    return {
        action        => $self->column( $row, 'action' ),
        created_at    => $self->column( $row, 'created_at' ),
        name          => $self->column( $row, 'name' ),
        permission_id => $self->column( $row, 'permission_id' ),
        resource_type => $self->column( $row, 'resource_type' ),
        ui            => {
            heading_id => $self->stable_id(
                'permission', $self->column( $row, 'permission_id' ),
                'heading'
            ),
        },
    };
}

sub role_permission ( $self, $row ) {
    return {
        created_at    => $self->column( $row, 'created_at' ),
        permission_id => $self->column( $row, 'permission_id' ),
        role_id       => $self->column( $row, 'role_id' ),
        ui            => {
            row_id => $self->stable_id(
                'role-permission',
                $self->column( $row, 'role_id' ),
                $self->column( $row, 'permission_id' )
            ),
        },
    };
}

sub role_binding ( $self, $result ) {
    my $binding = $self->unwrap( $result, 'binding' );

    return {
        binding_id         => $self->column( $binding, 'binding_id' ),
        created_at         => $self->column( $binding, 'created_at' ),
        created_by_user_id => $self->column( $binding, 'created_by_user_id' ),
        resource_id        => $self->column( $binding, 'resource_id' ),
        resource_type      => $self->column( $binding, 'resource_type' ),
        revoked_at         => $self->column( $binding, 'revoked_at' ),
        role_id            => $self->column( $binding, 'role_id' ),
        space_id           => $self->column( $binding, 'space_id' ),
        ui                 => {
            heading_id => $self->stable_id(
                'binding', $self->column( $binding, 'binding_id' ),
                'heading'
            ),
        },
        user_id => $self->column( $binding, 'user_id' ),
    };
}

sub audit_entry ( $self, $row ) {
    my $metadata = $self->column( $row, 'metadata' );

    return {
        action         => $self->column( $row, 'action' ),
        actor_id       => $self->column( $row, 'actor_id' ),
        audit_id       => $self->column( $row, 'audit_id' ),
        correlation_id => $self->column( $row, 'correlation_id' ),
        created_at     => $self->column( $row, 'created_at' ),
        metadata       => $metadata,
        metadata_items => $self->metadata_items($metadata),
        target_id      => $self->column( $row, 'target_id' ),
        target_type    => $self->column( $row, 'target_type' ),
        ui             => {
            heading_id => $self->stable_id(
                'audit', $self->column( $row, 'audit_id' ), 'heading'
            ),
        },
    };
}

sub outbox_message ( $self, $row ) {
    my $outbox_id = $self->column( $row, 'outbox_id' );

    return {
        attempt_count    => $self->column( $row, 'attempt_count' ),
        attempts         => $self->column( $row, 'attempts' ),
        available_at     => $self->column( $row, 'available_at' ),
        created_at       => $self->column( $row, 'created_at' ),
        event_id         => $self->column( $row, 'event_id' ),
        idempotency_key  => $self->column( $row, 'idempotency_key' ),
        job_type         => $self->column( $row, 'job_type' ),
        last_error       => $self->column( $row, 'last_error' ),
        last_error_class => $self->column( $row, 'last_error_class' ),
        locked_at        => $self->column( $row, 'locked_at' ),
        locked_by        => $self->column( $row, 'locked_by' ),
        locked_until     => $self->column( $row, 'locked_until' ),
        next_attempt_at  => $self->column( $row, 'next_attempt_at' ),
        outbox_id        => $outbox_id,
        queue            => $self->column( $row, 'queue' ),
        status           => $self->column( $row, 'status' ),
        ui               => {
            heading_id => $self->stable_id( 'outbox', $outbox_id, 'heading' ),
        },
    };
}

sub dead_letter ( $self, $row ) {
    my $dead_letter_id = $self->column( $row, 'dead_letter_id' );

    return {
        dead_letter_id  => $dead_letter_id,
        error_class     => $self->column( $row, 'error_class' ),
        error_message   => $self->column( $row, 'error_message' ),
        failure_type    => $self->column( $row, 'failure_type' ),
        first_failed_at => $self->column( $row, 'first_failed_at' ),
        last_failed_at  => $self->column( $row, 'last_failed_at' ),
        replay_status   => $self->column( $row, 'replay_status' ),
        retry_count     => $self->column( $row, 'retry_count' ),
        source_id       => $self->column( $row, 'source_id' ),
        source_table    => $self->column( $row, 'source_table' ),
        ui              => {
            heading_id =>
              $self->stable_id( 'dead-letter', $dead_letter_id, 'heading' ),
        },
    };
}

sub _dead_letter_with_replay ( $self, $row, $ids ) {
    my $letter = $self->dead_letter($row);
    $letter->{replay_command_id} =
      $self->string( $ids->{ $letter->{dead_letter_id} || q{} } );

    return $letter;
}

sub dead_letter_replay_response ( $self, $status, $replayed ) {
    return {
        replayed => ref $replayed eq 'HASH' ? { %{$replayed} } : {},
        status   => $status,
    };
}

sub metadata_items ( $self, $metadata ) {
    return [] if ref $metadata ne 'HASH';

    return [
        map {
            {
                name  => $_,
                value => $self->metadata_value( $metadata->{$_} ),
            }
        } sort keys %{$metadata}
    ];
}

sub metadata_value ( $self, $value ) {
    return q{}                 if !defined $value;
    return encode_json($value) if ref $value;

    return $value;
}

1;
