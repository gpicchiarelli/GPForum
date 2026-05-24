package GPForum::Controller::Admin;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my $DEFAULT_LIMIT       => 50;
const my $DASHBOARD_LIMIT     => 10;
const my $HTTP_OK             => 200;
const my $HTTP_BAD_REQUEST    => 400;
const my $HTTP_UNAUTHORIZED   => 401;
const my $HTTP_FORBIDDEN      => 403;
const my $HTTP_NOT_FOUND      => 404;
const my $HTTP_SERVER_ERROR   => 500;
const my $ADMIN_RESOURCE      => 'admin_console';
const my $ACTION_MANAGE       => 'manage';
const my $ACTION_VIEW         => 'view';
const my $ROLE_BINDING_TARGET => 'role_binding';
const my $STATUS_ROLE_BOUND   => 'role_bound';
const my $STATUS_ROLE_CREATED => 'role_created';
const my $STATUS_ROLE_REVOKED => 'role_binding_revoked';
const my $STATUS_PERMISSION   => 'permission_created';
const my $STATUS_ROLE_PERM    => 'role_permission_attached';

sub dashboard {
    my ($self) = @_;

    my $user_id = _authorized_user_id( $self, $ACTION_VIEW );
    return if !$user_id;

    my $payload = eval {
        return {
            audit_rows => [
                map { _audit_hash($_) } @{
                    $self->gp_admin_audit_review->recent(
                        { limit => $DASHBOARD_LIMIT }
                    )
                }
            ],
            csrf_token => $self->csrf_token,
            roles      => [
                map { _role_hash($_) } @{
                    $self->gp_role_catalog->list_roles(
                        { limit => $DASHBOARD_LIMIT }
                    )
                }
            ],
        };
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("admin dashboard failed: $EVAL_ERROR");
        return _system_failure($self);
    }

    return _render_payload( $self, 'admin/dashboard', $payload, $HTTP_OK );
}

sub roles {
    my ($self) = @_;

    my $user_id = _authorized_user_id( $self, $ACTION_VIEW );
    return if !$user_id;

    my $payload = eval {
        return {
            csrf_token  => $self->csrf_token,
            permissions => [
                map { _permission_hash($_) } @{
                    $self->gp_role_catalog->list_permissions(
                        { limit => _limit_param($self) }
                    )
                }
            ],
            roles => [
                map { _role_hash($_) } @{
                    $self->gp_role_catalog->list_roles(
                        { limit => _limit_param($self) }
                    )
                }
            ],
        };
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("admin roles failed: $EVAL_ERROR");
        return _system_failure($self);
    }

    return _render_payload( $self, 'admin/roles', $payload, $HTTP_OK );
}

sub create_role {
    my ($self) = @_;

    my $user_id = _authorized_write_user_id($self);
    return if !$user_id;

    my $name = _trim( $self->param('name') );
    return _bad_request( $self, { name => 'name is required' } )
      if !length $name;

    my $role = eval {
        return $self->gp_role_catalog->create_role(
            {
                description => _optional_param( $self, 'description' ),
                name        => $name,
            }
        );
    };

    return _system_failure($self) if $EVAL_ERROR;

    return _role_response( $self, $STATUS_ROLE_CREATED, $role );
}

sub create_permission {
    my ($self) = @_;

    my $user_id = _authorized_write_user_id($self);
    return if !$user_id;

    my %input = (
        action        => _trim( $self->param('action') ),
        name          => _trim( $self->param('name') ),
        resource_type => _trim( $self->param('resource_type') ),
    );
    my %errors = _required_errors( \%input, [qw(name resource_type action)] );
    return _bad_request( $self, \%errors ) if %errors;

    my $permission =
      eval { return $self->gp_role_catalog->create_permission( \%input ); };

    return _system_failure($self) if $EVAL_ERROR;

    return _permission_response( $self, $STATUS_PERMISSION, $permission );
}

sub attach_permission {
    my ($self) = @_;

    my $user_id = _authorized_write_user_id($self);
    return if !$user_id;

    my %input = (
        permission_id => _trim( $self->param('permission_id') ),
        role_id       => _trim( $self->param('role_id') ),
    );
    my %errors = _required_errors( \%input, [qw(role_id permission_id)] );
    return _bad_request( $self, \%errors ) if %errors;

    my $role_permission =
      eval { return $self->gp_role_catalog->attach_permission( \%input ); };

    return _system_failure($self) if $EVAL_ERROR;

    return _role_permission_response( $self, $STATUS_ROLE_PERM,
        $role_permission );
}

sub user_roles {
    my ($self) = @_;

    my $user_id = _authorized_user_id( $self, $ACTION_VIEW );
    return if !$user_id;

    my $target_user_id = _trim( $self->param('user_id') );
    return _bad_request( $self, { user_id => 'user_id is required' } )
      if !length $target_user_id;

    my $bindings = eval {
        return $self->gp_permission_review->roles_for_user( $target_user_id,
            { limit => _limit_param($self) },
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("admin user roles failed: $EVAL_ERROR");
        return _system_failure($self);
    }

    return _render_payload(
        $self,
        'admin/user_roles',
        {
            bindings   => [ map { _binding_hash($_) } @{$bindings} ],
            csrf_token => $self->csrf_token,
            user_id    => $target_user_id,
        },
        $HTTP_OK,
    );
}

sub bind_role {
    my ($self) = @_;

    my $actor_user_id = _authorized_write_user_id($self);
    return if !$actor_user_id;

    my %input = (
        actor_user_id => $actor_user_id,
        resource_id   => _optional_param( $self, 'resource_id' ),
        resource_type => _trim( $self->param('resource_type') ),
        role_id       => _trim( $self->param('role_id') ),
        space_id      => _optional_param( $self, 'space_id' ),
        user_id       => _trim( $self->param('user_id') ),
    );
    my %errors =
      _required_errors( \%input, [qw(user_id role_id resource_type)] );
    return _bad_request( $self, \%errors ) if %errors;

    my $bound =
      eval { return $self->gp_role_binding_store->bind_role( \%input ); };

    return _system_failure($self) if $EVAL_ERROR;

    return _binding_response( $self, $STATUS_ROLE_BOUND, $bound );
}

sub revoke_binding {
    my ($self) = @_;

    my $actor_user_id = _authorized_write_user_id($self);
    return if !$actor_user_id;

    my $revoked = eval {
        return $self->gp_role_binding_store->revoke_binding(
            $self->param('binding_id'),
            $actor_user_id, );
    };

    return _system_failure($self)                        if $EVAL_ERROR;
    return _not_found( $self, 'role binding not found' ) if !$revoked;

    return _binding_response( $self, $STATUS_ROLE_REVOKED, $revoked );
}

sub audit {
    my ($self) = @_;

    my $user_id = _authorized_user_id( $self, $ACTION_VIEW );
    return if !$user_id;

    my $target_type = _optional_param( $self, 'target_type' );
    my $target_id   = _optional_param( $self, 'target_id' );
    my $rows        = eval {
        if ( defined $target_type && defined $target_id ) {
            return $self->gp_admin_audit_review->for_target( $target_type,
                $target_id, { limit => _limit_param($self) },
            );
        }

        return $self->gp_admin_audit_review->recent(
            { limit => _limit_param($self) } );
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("admin audit failed: $EVAL_ERROR");
        return _system_failure($self);
    }

    return _render_payload(
        $self,
        'admin/audit',
        {
            audit_rows  => [ map { _audit_hash($_) } @{$rows} ],
            target_id   => $target_id,
            target_type => $target_type,
        },
        $HTTP_OK,
    );
}

sub _authorized_write_user_id {
    my ($controller) = @_;

    if ( $controller->validation->csrf_protect->has_error('csrf_token') ) {
        _csrf_failure($controller);
        return;
    }

    return _authorized_user_id( $controller, $ACTION_MANAGE );
}

sub _authorized_user_id {
    my ( $controller, $action ) = @_;

    my $user_id = $controller->session('user_id');
    if ( !$user_id ) {
        _unauthorized($controller);
        return;
    }

    my $allowed = $controller->gp_permission_gate->allowed(
        { user_id => $user_id },
        {
            resource_type => $ADMIN_RESOURCE,
            action        => $action,
        }
    );

    if ( !$allowed ) {
        _forbidden($controller);
        return;
    }

    return $user_id;
}

sub _role_response {
    my ( $controller, $status, $role ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json   => { status => $status, role => _role_hash($role) },
            status => $HTTP_OK,
        );
    }

    return $controller->redirect_to('admin_roles');
}

sub _permission_response {
    my ( $controller, $status, $permission ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json => {
                status     => $status,
                permission => _permission_hash($permission),
            },
            status => $HTTP_OK,
        );
    }

    return $controller->redirect_to('admin_roles');
}

sub _role_permission_response {
    my ( $controller, $status, $role_permission ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json => {
                role_permission => _role_permission_hash($role_permission),
                status          => $status,
            },
            status => $HTTP_OK,
        );
    }

    return $controller->redirect_to('admin_roles');
}

sub _binding_response {
    my ( $controller, $status, $binding ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json => {
                binding => _binding_hash($binding),
                status  => $status,
            },
            status => $HTTP_OK,
        );
    }

    return $controller->redirect_to('admin_roles');
}

sub _render_payload {
    my ( $controller, $template, $payload, $status ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render( json => $payload, status => $status );
    }

    return $controller->render(
        template => $template,
        %{$payload},
        status => $status,
    );
}

sub _render_error {
    my ( $controller, $status, $payload ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render( json => $payload, status => $status );
    }

    return $controller->render(
        template => 'forum/error',
        %{$payload},
        status => $status,
    );
}

sub _role_hash {
    my ($row) = @_;

    return {
        created_at  => _column( $row, 'created_at' ),
        description => _column( $row, 'description' ),
        name        => _column( $row, 'name' ),
        role_id     => _column( $row, 'role_id' ),
    };
}

sub _permission_hash {
    my ($row) = @_;

    return {
        action        => _column( $row, 'action' ),
        created_at    => _column( $row, 'created_at' ),
        name          => _column( $row, 'name' ),
        permission_id => _column( $row, 'permission_id' ),
        resource_type => _column( $row, 'resource_type' ),
    };
}

sub _role_permission_hash {
    my ($row) = @_;

    return {
        created_at    => _column( $row, 'created_at' ),
        permission_id => _column( $row, 'permission_id' ),
        role_id       => _column( $row, 'role_id' ),
    };
}

sub _binding_hash {
    my ($result) = @_;

    my $binding =
      ref $result eq 'HASH' && exists $result->{binding}
      ? $result->{binding}
      : $result;

    return {
        binding_id         => _column( $binding, 'binding_id' ),
        created_at         => _column( $binding, 'created_at' ),
        created_by_user_id => _column( $binding, 'created_by_user_id' ),
        resource_id        => _column( $binding, 'resource_id' ),
        resource_type      => _column( $binding, 'resource_type' ),
        revoked_at         => _column( $binding, 'revoked_at' ),
        role_id            => _column( $binding, 'role_id' ),
        space_id           => _column( $binding, 'space_id' ),
        user_id            => _column( $binding, 'user_id' ),
    };
}

sub _audit_hash {
    my ($row) = @_;

    return {
        action         => _column( $row, 'action' ),
        actor_id       => _column( $row, 'actor_id' ),
        audit_id       => _column( $row, 'audit_id' ),
        correlation_id => _column( $row, 'correlation_id' ),
        created_at     => _column( $row, 'created_at' ),
        metadata       => _column( $row, 'metadata' ),
        target_id      => _column( $row, 'target_id' ),
        target_type    => _column( $row, 'target_type' ),
    };
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    return;
}

sub _required_errors {
    my ( $input, $names ) = @_;

    my %errors;
    for my $name ( @{$names} ) {
        if ( !defined $input->{$name} || !length $input->{$name} ) {
            $errors{$name} = "$name is required";
        }
    }

    return %errors;
}

sub _limit_param {
    my ($controller) = @_;

    return $controller->param('limit') || $DEFAULT_LIMIT;
}

sub _optional_param {
    my ( $controller, $name ) = @_;

    my $value = _trim( $controller->param($name) );
    return length $value ? $value : undef;
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

sub _wants_json {
    my ($controller) = @_;

    my $format = $controller->param('format') || q{};
    return 1 if $format eq 'json';

    my $accept = $controller->req->headers->accept || q{};
    return $accept =~ m{application/json}msx ? 1 : 0;
}

sub _bad_request {
    my ( $controller, $errors ) = @_;

    return _render_error(
        $controller,
        $HTTP_BAD_REQUEST,
        {
            error  => 'The submitted admin request was invalid.',
            errors => $errors,
            status => 'invalid',
            title  => 'Invalid admin request',
        }
    );
}

sub _csrf_failure {
    my ($controller) = @_;

    _record_security_event(
        $controller,
        'csrf_failure',
        {
            status => $HTTP_FORBIDDEN,
        }
    );

    return _render_error(
        $controller,
        $HTTP_FORBIDDEN,
        {
            error  => 'Bad CSRF token',
            status => 'forbidden',
            title  => 'Forbidden',
        }
    );
}

sub _unauthorized {
    my ($controller) = @_;

    _record_security_event(
        $controller,
        'auth_denial',
        {
            status => $HTTP_UNAUTHORIZED,
        }
    );

    return _render_error(
        $controller,
        $HTTP_UNAUTHORIZED,
        {
            error  => 'authentication required',
            status => 'unauthorized',
            title  => 'Authentication required',
        }
    );
}

sub _forbidden {
    my ($controller) = @_;

    _record_security_event(
        $controller,
        'auth_denial',
        {
            reason => 'forbidden',
            status => $HTTP_FORBIDDEN,
        }
    );

    return _render_error(
        $controller,
        $HTTP_FORBIDDEN,
        {
            error  => 'permission denied',
            status => 'forbidden',
            title  => 'Forbidden',
        }
    );
}

sub _not_found {
    my ( $controller, $error ) = @_;

    return _render_error(
        $controller,
        $HTTP_NOT_FOUND,
        {
            error  => $error,
            status => 'not_found',
            title  => 'Not found',
        }
    );
}

sub _system_failure {
    my ($controller) = @_;

    return _render_error(
        $controller,
        $HTTP_SERVER_ERROR,
        {
            error  => 'internal error',
            status => 'error',
            title  => 'Internal error',
        }
    );
}

sub _record_security_event {
    my ( $controller, $event_type, $metadata ) = @_;

    return $controller->gp_security_telemetry->record(
        $event_type,
        {
            %{$metadata}, route => _current_route_name($controller),
        }
    );
}

sub _current_route_name {
    my ($controller) = @_;

    return eval { return $controller->current_route; } || 'unknown';
}

1;
