# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Moderation::Base;

use Const::Fast;
use Mojo::Base 'GPForum::Controller::Base', -signatures;
use v5.40;

use GPForum::Web::Access;
use GPForum::Web::Guard;
use GPForum::Web::ModerationAccess;
use GPForum::Web::SecurityEvent;
use GPForum::Web::UrlId;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

# Route placeholder holding the resource a write acts on, per permission
# resource type. Stash captures are read instead of query or body parameters
# so a scoped role binding cannot be widened by an injected parameter.
const my %WRITE_SCOPE_CAPTURE => (
    moderation_action => 'action_id',
    post              => 'post_id',
    report            => 'report_id',
    suspension        => 'suspension_id',
    thread            => 'thread_id',
    user              => 'user_id',
);

# The workflow's own name for a row whose placeholder says less, so a
# malformed id answers word for word as one naming no row.
const my %PATH_ID_NOUN => ( action_id => 'moderation action' );

sub moderation_access {
    return GPForum::Web::ModerationAccess->new;
}

sub queue_limit ($self) {
    return $self->moderation_access->queue_limit( $self->param('limit') );
}

sub authorized_write_user_id ( $self, $resource_type, $action = undef ) {
    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        GPForum::Web::SecurityEvent->new->csrf_failure($self);
        return;
    }

    my $access   = $self->moderation_access;
    my $decision = $access->authorization_target( $resource_type, $action );
    my $user_id  = $self->_scoped_user_id( $decision,
        $self->write_permission_scope( $decision->{resource_type} ) );
    if ( !$user_id ) {
        return;
    }
    my $rate = $self->gp_rate_limiter->check(
        $access->write_rate_input(
            { action => $access->write_action, actor_id => $user_id }
        )
    );
    if ( !$rate->{ok} ) {
        GPForum::Web::SecurityEvent->new->rate_limited($self);
        return;
    }

    return $user_id;
}

sub authorized_user_id ( $self, $resource_type, $action = undef ) {
    return $self->_scoped_user_id(
        $self->moderation_access->authorization_target(
            $resource_type, $action
        ),
        $self->global_permission_scope,
    );
}

sub write_permission_scope ( $self, $resource_type ) {
    if (   !defined $resource_type
        || !exists $WRITE_SCOPE_CAPTURE{$resource_type} )
    {
        return $self->global_permission_scope;
    }

    return {
        %{ $self->global_permission_scope },
        resource_id => $self->stash( $WRITE_SCOPE_CAPTURE{$resource_type} ),
    };
}

sub _scoped_user_id ( $self, $decision, $scope ) {
    my $user_id = GPForum::Web::Access->new->user_id($self);
    if ( !$user_id ) {
        GPForum::Web::SecurityEvent->new->unauthorized($self);
        return;
    }

    # Before the permission gate: it binds the path id as a role binding's
    # resource_id, and PostgreSQL refusing a malformed one answered 500 (503
    # from the workflow when no binding was scoped to it, as on revoke).
    if ( my $malformed = GPForum::Web::UrlId->malformed_path_id($self) ) {
        $self->_not_found(
            GPForum::Web::UrlId->not_found_error( $malformed, \%PATH_ID_NOUN )
        );
        return;
    }
    my $permission = {
        action        => $decision->{action},
        resource_type => $decision->{resource_type},
        %{$scope},
    };
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

sub report_write_response ( $self, $result, $ok_status ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->action_response( $ok_status, $result->{stored} );
}

sub moderation_write_response ( $self, $result, $ok_status ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->moderation_action_response( $ok_status, $result->{stored} );
}

sub suspension_write_response ( $self, $result, $ok_status ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->suspension_response( $ok_status, $result->{stored} );
}

# The response a failed write answers with, or undef when it did not fail.
sub write_failure ( $self, $result ) {
    my $access = $self->moderation_access;
    my $guard  = GPForum::Web::Guard->new;
    if ( $access->is_failed($result) ) {
        return $guard->service_unavailable($self);
    }

    my $status = $access->failure_status($result) || q{};
    if ( $status eq 'not_found' ) {
        return $self->_not_found( $result->{error} );
    }
    if ( $status eq 'invalid' ) {
        return $guard->bad_request( $self,
            $access->invalid_request( $result->{errors} ) );
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

sub moderation_action_response ( $self, $status, $action ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_moderation_view_model->moderation_action_response(
                $status, $action
            ),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $status, 'moderation_reports' );
}

sub suspension_response ( $self, $status, $suspension ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_moderation_view_model->suspension_response(
                $status, $suspension,
            ),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $status, 'moderation_reports' );
}

sub action_response ( $self, $status, $report ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_moderation_view_model->report_action_response(
                $status, $report
            ),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $status, 'moderation_reports' );
}

sub status_param ($self) {
    return $self->moderation_access->queue_status(
        $self->_trim( $self->param('status') ) );
}

sub suspension_status_param ($self) {
    return $self->moderation_access->suspension_status(
        $self->_trim( $self->param('status') ) );
}

sub reason_param ($self) {
    return $self->_trim( $self->param('reason') );
}

sub _html_success ( $self, $status, $route ) {
    $self->set_success_flash(
        $self->moderation_access->write_flash_key($status) );

    return $self->redirect_to($route);
}

sub _wants_json ($self) {
    return GPForum::Web::Access->new->wants_json($self);
}

sub _not_found ( $self, $error ) {
    return GPForum::Web::Guard->new->not_found( $self, $error );
}

sub system_failure ($self) {
    return GPForum::Web::Guard->new->system_failure($self);
}

1;

__END__

=head1 NAME

GPForum::Controller::Moderation::Base - Shared moderation HTTP helpers.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use Mojo::Base 'GPForum::Controller::Moderation::Base';

=head1 DESCRIPTION

Owns CSRF, authorization, rate-limit checks, telemetry, and Guard errors
used by moderation queue, action, and suspension controllers. Queue
limits, write rate-limit hashes, default filters, permission-target
hashes, and failure-status mapping live on
L<GPForum::Web::ModerationAccess>.

=head1 SUBROUTINES/METHODS

=head2 authorized_write_user_id

Rejects invalid CSRF tokens, unauthorized moderation writes, and
rate-limited actors. The permission check carries the scope returned by
L</write_permission_scope>. A signed-in actor whose route id is not a
uuid gets 404 before the permission gate or the workflow runs a query
(L<GPForum::Web::UrlId>).

=head2 authorized_user_id

Requires an authenticated actor with the requested moderation permission at
global scope. Read routes address no single resource, so they deliberately
pass L<GPForum::Controller::Base/global_permission_scope>.



=head2 write_permission_scope

Returns the permission scope for a write against the given permission
resource type. The resource id comes from the route placeholder that names
the acted-on row (C<post_id>, C<thread_id>, C<report_id>, C<action_id>,
C<suspension_id>, or C<user_id>), read from the stash so query and body
parameters cannot widen a scoped role binding. Resource types with no
matching placeholder fall back to
L<GPForum::Controller::Base/global_permission_scope>.

=head2 write_failure

Maps workflow statuses to HTTP error responses.

=head1 DIAGNOSTICS

HTTP errors are rendered as JSON or HTML depending on the request.

=head1 CONFIGURATION AND ENVIRONMENT

Uses permission and moderation helpers registered during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Base>, L<GPForum::Web::Access>,
L<GPForum::Web::Guard>, L<GPForum::Web::ModerationAccess>,
L<GPForum::Web::Responder>, L<GPForum::Web::SecurityEvent>, and
L<GPForum::Web::UrlId>.

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
