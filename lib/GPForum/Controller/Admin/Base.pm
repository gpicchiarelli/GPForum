# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Admin::Base;

use Const::Fast;
use Mojo::Base 'GPForum::Controller::Base', -signatures;
use v5.40;

use GPForum::Web::Access;
use GPForum::Web::AdminAccess;
use GPForum::Web::Guard;
use GPForum::Web::SecurityEvent;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

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
        GPForum::Web::SecurityEvent->new->csrf_failure($self);
        return;
    }

    my $access  = $self->admin_access;
    my $user_id = $self->_scoped_user_id( $access->manage_action,
        $self->write_permission_scope );
    if ( !$user_id ) {
        return;
    }
    my $decision = $self->gp_rate_limiter->check(
        $access->write_rate_input(
            { action => $access->write_action, actor_id => $user_id }
        )
    );
    if ( !$decision->{ok} ) {
        GPForum::Web::SecurityEvent->new->rate_limited($self);
        return;
    }

    return $user_id;
}

sub authorized_user_id ( $self, $action ) {
    return $self->_scoped_user_id( $action, $self->global_permission_scope );
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
    my $user_id = GPForum::Web::Access->new->user_id($self);
    if ( !$user_id ) {
        GPForum::Web::SecurityEvent->new->unauthorized($self);
        return;
    }
    my $permission =
      { %{ $self->admin_access->permission_target($action) }, %{$scope} };
    if (
        !$self->gp_permission_gate->allowed(
            { user_id => $user_id }, $permission
        )
      )
    {
        GPForum::Web::Guard->new->log_denial( $self, $user_id, $permission );
        GPForum::Web::SecurityEvent->new->forbidden($self);
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

# The response a failed write answers with, or undef when it did not fail.
sub write_failure ( $self, $result ) {
    my $access = $self->admin_access;
    my $guard  = GPForum::Web::Guard->new;
    if ( $access->is_failed($result) ) {
        return $guard->service_unavailable($self);
    }

    my $status = $access->failure_status($result) // q{};
    if ( $status eq 'not_found' ) {
        return $guard->not_found( $self, $result->{error} );
    }
    if ( $status eq 'invalid' ) {
        return $self->_bad_request( $result->{errors} );
    }
    if ( $status eq 'conflict' ) {
        return $guard->conflict(
            $self,
            {
                error => $result->{error} || 'idempotency conflict',
                title => 'Conflict',
            }
        );
    }

    return undef;
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
# flash -- a warning, naming the tags left, when a purge did not reach the
# shared cache.
sub maintenance_response ( $self, $status, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json   => { result => $stored, status => $status },
            status => $HTTP_OK,
        );
    }

    my $access    = $self->admin_access;
    my $flash_key = $access->write_flash_key($status);
    if ($flash_key) {
        $self->flash(
            $access->write_flash_type($status) => $self->t(
                $flash_key, $access->maintenance_flash_variables($stored)
            )
        );
    }

    return $self->redirect_to( $access->jobs_redirect );
}

# A test message's or an antivirus check's answer: JSON with the outcome, or
# back to the settings page, which shows the audited result in full, with a
# flash that is a warning when the check did not pass.
sub diagnostics_response ( $self, $status, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json   => { result => $stored, status => $status },
            status => $HTTP_OK,
        );
    }

    my $access    = $self->admin_access;
    my $flash_key = $access->write_flash_key($status);
    if ($flash_key) {
        $self->flash(
            $access->write_flash_type($status) => $self->t($flash_key) );
    }

    return $self->redirect_to( $access->settings_redirect );
}

sub _html_success ( $self, $status, $route ) {
    $self->set_success_flash( $self->admin_access->write_flash_key($status) );

    return $self->redirect_to($route);
}

sub _wants_json ($self) {
    return GPForum::Web::Access->new->wants_json($self);
}

sub _bad_request ( $self, $errors ) {
    return GPForum::Web::Guard->new->bad_request( $self,
        $self->admin_access->invalid_request($errors) );
}

sub system_failure ($self) {
    return GPForum::Web::Guard->new->system_failure($self);
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
pass L<GPForum::Controller::Base/global_permission_scope>.



=head2 write_permission_scope

Returns the permission scope for an admin write. Only C<bind_role> names
the scope it acts on, so its C<resource_id> and C<space_id> parameters
become the requested scope and every other admin write stays global. Role,
permission, category, and binding-revoke writes therefore still require a
global role binding.

=head2 write_failure

Maps workflow statuses to HTTP error responses.

=head2 maintenance_response

Answers a maintenance command: JSON with the status and the stored result,
or a redirect to the jobs page with a flash whose type follows the status
(a warning for C<cache_purged_locally>, with the tags the purge did not
reach).

=head2 dead_letter_replay_response

Answers a replayed dead letter: JSON, or a redirect to the jobs page with a
flash.

=head2 diagnostics_response

Answers a test message or an antivirus check: JSON with the result, or a
redirect to the settings page with a flash whose type follows the outcome.

=head1 DIAGNOSTICS

HTTP errors are rendered as JSON or HTML depending on the request.

=head1 CONFIGURATION AND ENVIRONMENT

Uses permission and admin helpers registered during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Base>, L<GPForum::Web::Access>,
L<GPForum::Web::AdminAccess>, L<GPForum::Web::Guard>,
L<GPForum::Web::Responder>, and L<GPForum::Web::SecurityEvent>.

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
