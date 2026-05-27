package GPForum::ViewModel::Admin::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base';
use Mojo::JSON qw(encode_json);

our $VERSION = '0.001';

sub dashboard {
    my ( $self, %input ) = @_;

    return {
        audit_rows =>
          [ map { $self->audit_entry($_) } @{ $input{audit_rows} || [] } ],
        csrf_token => $input{csrf_token},
        roles      => [ map { $self->role($_) } @{ $input{roles} || [] } ],
        summary    => $input{summary} || {},
    };
}

sub roles_page {
    my ( $self, %input ) = @_;

    return {
        csrf_token  => $input{csrf_token},
        permissions =>
          [ map { $self->permission($_) } @{ $input{permissions} || [] } ],
        roles => [ map { $self->role($_) } @{ $input{roles} || [] } ],
    };
}

sub user_roles_page {
    my ( $self, %input ) = @_;

    return {
        bindings =>
          [ map { $self->role_binding($_) } @{ $input{bindings} || [] } ],
        csrf_token => $input{csrf_token},
        user_id    => $input{user_id},
    };
}

sub users_page {
    my ( $self, %input ) = @_;

    return {
        status => $input{status},
        users  => [ map { $self->user($_) } @{ $input{users} || [] } ],
    };
}

sub jobs_page {
    my ( $self, %input ) = @_;

    my $jobs = $input{jobs} || {};

    return {
        jobs => {
            dead_letters => [
                map { $self->dead_letter($_) } @{ $jobs->{dead_letters} || [] }
            ],
            outbox_messages => [
                map { $self->outbox_message($_) }
                  @{ $jobs->{outbox_messages} || [] }
            ],
        },
        status => $input{status},
    };
}

sub status_page {
    my ( $self, %input ) = @_;

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

sub audit_page {
    my ( $self, %input ) = @_;

    return {
        audit_rows =>
          [ map { $self->audit_entry($_) } @{ $input{audit_rows} || [] } ],
        target_id   => $input{target_id},
        target_type => $input{target_type},
    };
}

sub user {
    my ( $self, $row ) = @_;

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

sub role {
    my ( $self, $row ) = @_;

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

sub permission {
    my ( $self, $row ) = @_;

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

sub role_permission {
    my ( $self, $row ) = @_;

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

sub role_binding {
    my ( $self, $result ) = @_;

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

sub audit_entry {
    my ( $self, $row ) = @_;

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

sub outbox_message {
    my ( $self, $row ) = @_;

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

sub dead_letter {
    my ( $self, $row ) = @_;

    my $dead_letter_id = $self->column( $row, 'dead_letter_id' );

    return {
        dead_letter_id  => $dead_letter_id,
        error_class     => $self->column( $row, 'error_class' ),
        error_message   => $self->column( $row, 'error_message' ),
        first_failed_at => $self->column( $row, 'first_failed_at' ),
        last_failed_at  => $self->column( $row, 'last_failed_at' ),
        retry_count     => $self->column( $row, 'retry_count' ),
        source_id       => $self->column( $row, 'source_id' ),
        source_table    => $self->column( $row, 'source_table' ),
        ui              => {
            heading_id =>
              $self->stable_id( 'dead-letter', $dead_letter_id, 'heading' ),
        },
    };
}

sub metadata_items {
    my ( $self, $metadata ) = @_;

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

sub metadata_value {
    my ( $self, $value ) = @_;

    return q{}                 if !defined $value;
    return encode_json($value) if ref $value;

    return $value;
}

1;
