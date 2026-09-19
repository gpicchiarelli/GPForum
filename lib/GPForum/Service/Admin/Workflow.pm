package GPForum::Service::Admin::Workflow;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

our $VERSION = '0.001';

const my %ALLOWED_VISIBILITY => (
    members => 1,
    private => 1,
    public  => 1,
);

has binding_store  => undef;
has category_store => undef;
has logger         => undef;
has role_catalog   => undef;

sub create_role {
    my ( $self, $input ) = @_;

    my $command = {
        actor_user_id => $input->{actor_user_id},
        description   => _optional( $input->{description} ),
        name          => _trim( $input->{name} ),
    };
    my $invalid = $self->_missing_fields( $command, ['name'] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_run_store(
        'role not found',
        sub { return $self->role_catalog->create_role($command); },
    );
}

sub create_permission {
    my ( $self, $input ) = @_;

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

    return $self->_run_store(
        'permission not found',
        sub { return $self->role_catalog->create_permission($command); },
    );
}

sub attach_permission {
    my ( $self, $input ) = @_;

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

    return $self->_run_store(
        'role permission not found',
        sub { return $self->role_catalog->attach_permission($command); },
    );
}

sub bind_role {
    my ( $self, $input ) = @_;

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

    return $self->_run_store(
        'role binding not found',
        sub { return $self->binding_store->bind_role($command); },
    );
}

sub revoke_binding {
    my ( $self, $input ) = @_;

    return $self->_run_store(
        'role binding not found',
        sub {
            return $self->binding_store->revoke_binding( $input->{binding_id},
                $input->{actor_user_id} );
        },
    );
}

sub create_category {
    my ( $self, $input ) = @_;

    my $command = $self->_category_command($input);
    my $invalid = $self->_invalid_category( $command, ['title'] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_category_store_result( $command, 'create_category',
        'space not found' );
}

sub update_category {
    my ( $self, $input ) = @_;

    my $command = $self->_category_command($input);
    my $invalid = $self->_invalid_category( $command, ['category_id'] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_category_store_result( $command, 'update_category',
        'category not found' );
}

sub _category_command {
    my ( undef, $input ) = @_;

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

sub _invalid_category {
    my ( $self, $command, $required ) = @_;

    my $missing = $self->_missing_fields( $command, $required );
    if ($missing) {
        return $missing;
    }

    return $self->_invalid_visibility($command);
}

sub _invalid_visibility {
    my ( undef, $command ) = @_;

    if ( _visibility_ok( $command->{visibility} ) ) {
        return;
    }

    return _result(
        status => 'invalid',
        errors => { visibility => 'visibility is invalid' },
    );
}

sub _visibility_ok {
    my ($value) = @_;

    my $trimmed = _trim($value);
    if ( !length $trimmed ) {
        return 1;
    }

    if ( exists $ALLOWED_VISIBILITY{$trimmed} ) {
        return 1;
    }

    return 0;
}

sub _category_store_result {
    my ( $self, $command, $method, $not_found ) = @_;

    return $self->_run_store( $not_found,
        sub { return $self->category_store->$method($command); },
    );
}

sub _missing_fields {
    my ( undef, $input, $names ) = @_;

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

    return;
}

sub _run_store {
    my ( $self, $not_found, $code ) = @_;

    my $stored = $self->_eval_store($code);
    if ( $stored->{failed} ) {
        return _result(
            status => 'failed',
            error  => 'admin store failed',
        );
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

sub _eval_store {
    my ( $self, $code ) = @_;

    my $value = eval { return $code->(); };
    if ($EVAL_ERROR) {
        $self->_log_error("admin write failed: $EVAL_ERROR");
        return { failed => 1 };
    }

    return { value => $value };
}

sub _result {
    my (%input) = @_;

    return {
        error  => $input{error},
        errors => $input{errors},
        ok     => ( $input{status} || q{} ) eq 'ok' ? 1 : 0,
        status => $input{status} || 'failed',
        stored => $input{stored},
    };
}

sub _optional {
    my ($value) = @_;

    my $trimmed = _trim($value);
    return length $trimmed ? $trimmed : undef;
}

sub _trim {
    my ($value) = @_;

    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _log_error {
    my ( $self, $message ) = @_;

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
            name          => $name,
        }
    );

=head1 DESCRIPTION

Application boundary for admin catalog, role-binding, and category writes.
Validates required command fields, delegates persistence to C<RoleCatalog>,
C<RoleBindingStore>, and C<CategoryStore>, and returns a normalized result
hash. Stores keep transaction, event, audit, and outbox ownership.

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

=head1 DIAGNOSTICS

Returns C<invalid>, C<not_found>, or C<failed> statuses instead of throwing for
expected write outcomes. Unexpected store exceptions are logged and mapped to
C<failed>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses role catalog, binding, and category stores supplied by the composition
root.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Command-id replay is not required; stores keep their existing name/scope
idempotency.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
