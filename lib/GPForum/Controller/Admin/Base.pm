# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Admin::Base;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use GPForum::Web::Access;
use GPForum::Web::AdminAccess;
use GPForum::Web::Guard;
use GPForum::Web::Responder;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_TOO_MANY     => 429;

# Binding writes are the only admin action whose request names the scope it
# acts on. Other admin writes ignore resource_id and space_id, so reading
# those parameters for them would let an actor pick a scope the action never
# touches.
const my $SCOPED_WRITE_ACTION => 'bind_role';

sub admin_access {
    return GPForum::Web::AdminAccess->new;
}

sub limit_param ($self) {
    return $self->admin_access->page_limit( $self->param('limit') );
}

sub authorized_write_user_id ($self) {
    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        $self->_csrf_failure;
        return;
    }

    my $user_id = $self->_scoped_user_id( $self->admin_access->manage_action,
        $self->write_permission_scope );
    if ( !$user_id ) {
        return;
    }
    if ( !$self->_allowed($user_id) ) {
        $self->_rate_limited;
        return;
    }

    return $user_id;
}

sub authorized_user_id ( $self, $action ) {
    return $self->_scoped_user_id( $action, $self->global_permission_scope );
}

sub global_permission_scope {
    return {
        resource_id => undef,
        space_id    => undef,
    };
}

sub write_permission_scope ($self) {
    if ( ( $self->stash('action') || q{} ) ne $SCOPED_WRITE_ACTION ) {
        return $self->global_permission_scope;
    }

    return {
        resource_id => $self->optional_param('resource_id'),
        space_id    => $self->optional_param('space_id'),
    };
}

sub _scoped_user_id ( $self, $action, $scope ) {
    my $user_id = $self->_current_user_id;
    if ( !$user_id ) {
        $self->_unauthorized;
        return;
    }
    my $permission = $self->_permission_target( $action, $scope );
    if (
        !$self->gp_permission_gate->allowed(
            { user_id => $user_id }, $permission
        )
      )
    {
        GPForum::Web::Guard->new->log_denial( $self, $user_id, $permission );
        $self->_forbidden;
        return;
    }

    return $user_id;
}

sub role_write_response ( $self, $result, $ok_status ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->role_response( $ok_status, $result->{stored} );
}

sub permission_write_response ( $self, $result, $ok_status ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->permission_response( $ok_status, $result->{stored} );
}

sub role_permission_write_response ( $self, $result, $ok_status ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->role_permission_response( $ok_status, $result->{stored} );
}

sub binding_write_response ( $self, $result, $ok_status ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->binding_response( $ok_status, $result->{stored} );
}

sub category_write_response ( $self, $result, $ok_status ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->category_response( $ok_status, $result->{stored} );
}

sub write_failure ( $self, $result ) {
    if ( $self->admin_access->is_failed($result) ) {
        return $self->_service_unavailable;
    }

    return $self->_mapped_failure($result);
}

sub _mapped_failure ( $self, $result ) {
    return $self->_status_failure( $result,
        $self->admin_access->failure_status($result) );
}

sub _status_failure ( $self, $result, $status ) {
    if ( !defined $status ) {
        return;
    }
    if ( $status eq 'not_found' ) {
        return $self->_not_found( $result->{error} );
    }
    if ( $status eq 'invalid' ) {
        return $self->_bad_request( $result->{errors} );
    }
    if ( $status eq 'conflict' ) {
        return $self->_conflict( $result->{error} );
    }

    return;
}

sub role_response ( $self, $status, $role ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json =>
              $self->gp_admin_view_model->role_response( $status, $role, ),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $status,
        $self->admin_access->default_redirect );
}

sub permission_response ( $self, $status, $permission ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_admin_view_model->permission_response(
                $status, $permission,
            ),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $status,
        $self->admin_access->default_redirect );
}

sub role_permission_response ( $self, $status, $role_permission ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_admin_view_model->role_permission_response(
                $status, $role_permission,
            ),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $status,
        $self->admin_access->default_redirect );
}

sub binding_response ( $self, $status, $binding ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_admin_view_model->role_binding_response(
                $status, $binding,
            ),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $status,
        $self->admin_access->default_redirect );
}

sub category_response ( $self, $status, $category ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_admin_view_model->category_response(
                $status, $category,
            ),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $status,
        $self->admin_access->categories_redirect );
}

sub dead_letter_replay_response ( $self, $status, $replayed ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_admin_view_model->dead_letter_replay_response(
                $status, $replayed,
            ),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $status, $self->admin_access->jobs_redirect );
}

# A maintenance command's answer: JSON, or back to the jobs page with a
# flash.
sub maintenance_response ( $self, $status, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json   => { result => $stored, status => $status },
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $status, $self->admin_access->jobs_redirect );
}

sub render_payload ( $self, $input ) {
    return GPForum::Web::Responder->new->payload(
        {
            controller => $self,
            payload    => $input->{payload},
            status     => $input->{status},
            template   => $input->{template},
        }
    );
}

sub optional_param ( $self, $name ) {
    my $value = $self->_trim( $self->param($name) );
    my $optional;
    if ( length $value ) {
        $optional = $value;
    }

    return $optional;
}

sub _permission_target ( $self, $action, $scope ) {
    return { %{ $self->admin_access->permission_target($action) }, %{$scope} };
}

sub _allowed ( $self, $user_id ) {
    my $decision = $self->gp_rate_limiter->check(
        $self->admin_access->write_rate_input(
            {
                action   => $self->admin_access->write_action,
                actor_id => $user_id,
            }
        )
    );

    return $decision->{ok};
}

sub _current_user_id ($self) {
    return GPForum::Web::Access->new->user_id($self);
}

sub _html_success ( $self, $status, $route ) {
    $self->_set_success_flash( $self->admin_access->write_flash_key($status) );

    return $self->redirect_to($route);
}

sub _set_success_flash ( $self, $flash_key ) {
    if ( !$flash_key ) {
        return;
    }

    $self->flash( success => $self->t($flash_key) );

    return;
}

sub _wants_json ($self) {
    return GPForum::Web::Access->new->wants_json($self);
}

sub command_id_param ($self) {
    my $command_id = $self->_trim( $self->param('command_id') );
    if ( length $command_id ) {
        return $command_id;
    }

    return $self->_trim( $self->param('idempotency_key') );
}

sub _trim ( $, $value ) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _bad_request ( $self, $errors ) {
    return GPForum::Web::Guard->new->bad_request( $self,
        $self->admin_access->invalid_request($errors) );
}

sub _csrf_failure ($self) {
    $self->_record_security_event(
        'csrf_failure',
        {
            status => $HTTP_FORBIDDEN,
        }
    );

    return GPForum::Web::Guard->new->csrf_failure($self);
}

sub _unauthorized ($self) {
    $self->_record_security_event(
        'auth_denial',
        {
            status => $HTTP_UNAUTHORIZED,
        }
    );

    return GPForum::Web::Guard->new->unauthorized($self);
}

sub _forbidden ($self) {
    $self->_record_security_event(
        'auth_denial',
        {
            reason => 'forbidden',
            status => $HTTP_FORBIDDEN,
        }
    );

    return GPForum::Web::Guard->new->forbidden($self);
}

sub _rate_limited ($self) {
    $self->_record_security_event(
        'rate_limit_hit',
        {
            status => $HTTP_TOO_MANY,
        }
    );

    return GPForum::Web::Guard->new->rate_limited($self);
}

sub _not_found ( $self, $error ) {
    return GPForum::Web::Guard->new->not_found( $self, $error );
}

sub _conflict ( $self, $error ) {
    return GPForum::Web::Guard->new->conflict(
        $self,
        {
            error => $error || 'idempotency conflict',
            title => 'Conflict',
        }
    );
}

sub system_failure ($self) {
    return GPForum::Web::Guard->new->system_failure($self);
}

sub _service_unavailable ($self) {
    return GPForum::Web::Guard->new->service_unavailable($self);
}

sub _record_security_event ( $self, $event_type, $metadata ) {
    return $self->gp_security_telemetry->record(
        $event_type,
        {
            %{$metadata}, route => $self->_current_route_name,
        }
    );
}

sub _current_route_name ($self) {
    my $route = eval { return $self->current_route; };
    if ($route) {
        return $route;
    }

    return 'unknown';
}

1;

__END__

=head1 NAME

GPForum::Controller::Admin::Base - Shared admin HTTP helpers.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use Mojo::Base 'GPForum::Controller::Admin::Base';

=head1 DESCRIPTION

Owns CSRF, authorization, rate-limit checks, telemetry, and Guard errors
used by admin review, catalog, and binding controllers. Page limits,
write rate-limit hashes, permission-target hashes, and failure-status
mapping live on L<GPForum::Web::AdminAccess>.

=head1 SUBROUTINES/METHODS

=head2 authorized_write_user_id

Rejects invalid CSRF tokens, unauthorized admin writes, and rate-limited
actors. The permission check carries the scope returned by
L</write_permission_scope>.

=head2 authorized_user_id

Requires an authenticated actor with the requested admin permission at
global scope. Console reads span the whole console, so they deliberately
pass L</global_permission_scope>.

=head2 global_permission_scope

Returns the explicit unscoped permission scope: both C<resource_id> and
C<space_id> undefined. L<GPForum::Service::Admin::PermissionGate> then
accepts global role bindings only.

=head2 write_permission_scope

Returns the permission scope for an admin write. Only C<bind_role> names
the scope it acts on, so its C<resource_id> and C<space_id> parameters
become the requested scope and every other admin write stays global. Role,
permission, category, and binding-revoke writes therefore still require a
global role binding.

=head2 write_failure

Maps workflow statuses to HTTP error responses.

=head2 maintenance_response

Answers a maintenance command: JSON, or a redirect to the jobs page with a
flash.

=head2 dead_letter_replay_response

Answers a replayed dead letter: JSON, or a redirect to the jobs page with a
flash.

=head1 DIAGNOSTICS

HTTP errors are rendered as JSON or HTML depending on the request.

=head1 CONFIGURATION AND ENVIRONMENT

Uses permission and admin helpers registered during application startup.

=head1 DEPENDENCIES

Uses L<Mojolicious::Controller>, L<GPForum::Web::Access>,
L<GPForum::Web::AdminAccess>, L<GPForum::Web::Guard>, and
L<GPForum::Web::Responder>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Helpers are HTTP-oriented and must not talk to DBIx::Class resultsets.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
