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

sub audit_page {
    my ( $self, %input ) = @_;

    return {
        audit_rows =>
          [ map { $self->audit_entry($_) } @{ $input{audit_rows} || [] } ],
        target_id   => $input{target_id},
        target_type => $input{target_type},
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
    };
}

sub role_permission {
    my ( $self, $row ) = @_;

    return {
        created_at    => $self->column( $row, 'created_at' ),
        permission_id => $self->column( $row, 'permission_id' ),
        role_id       => $self->column( $row, 'role_id' ),
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
        user_id            => $self->column( $binding, 'user_id' ),
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
