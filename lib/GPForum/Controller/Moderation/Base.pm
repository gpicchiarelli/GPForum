# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Moderation::Base;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use GPForum::Web::Access;
use GPForum::Web::Guard;
use GPForum::Web::ModerationAccess;
use GPForum::Web::Responder;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_TOO_MANY     => 429;

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

sub moderation_access {
    return GPForum::Web::ModerationAccess->new;
}

sub queue_limit ($self) {
    return $self->moderation_access->queue_limit( $self->param('limit') );
}

sub authorized_write_user_id ( $self, $resource_type, $action = undef ) {
    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        $self->_csrf_failure;
        return;
    }

    my $decision =
      $self->moderation_access->authorization_target( $resource_type, $action );
    my $user_id = $self->_scoped_user_id( $decision,
        $self->write_permission_scope( $decision->{resource_type} ) );
    if ( !$user_id ) {
        return;
    }
    if ( !$self->_allowed($user_id) ) {
        $self->_rate_limited;
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

sub global_permission_scope {
    return {
        resource_id => undef,
        space_id    => undef,
    };
}

sub write_permission_scope ( $self, $resource_type ) {
    my $capture = _write_scope_capture($resource_type);
    if ( !defined $capture ) {
        return $self->global_permission_scope;
    }

    return {
        %{ $self->global_permission_scope },
        resource_id => $self->stash($capture),
    };
}

sub _write_scope_capture ($resource_type) {
    my $capture;
    if ( defined $resource_type
        && exists $WRITE_SCOPE_CAPTURE{$resource_type} )
    {
        $capture = $WRITE_SCOPE_CAPTURE{$resource_type};
    }

    return $capture;
}

sub _scoped_user_id ( $self, $decision, $scope ) {
    my $user_id = $self->_current_user_id;
    if ( !$user_id ) {
        $self->_unauthorized;
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
        $self->_forbidden;
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

sub write_failure ( $self, $result ) {
    if ( $self->moderation_access->is_failed($result) ) {
        return $self->_service_unavailable;
    }

    return $self->_mapped_failure($result);
}

sub _mapped_failure ( $self, $result ) {
    my $status = $self->moderation_access->failure_status($result) || q{};
    if ( $status eq 'not_found' ) {
        return $self->_not_found( $result->{error} );
    }

    return $self->_client_failure( $result, $status );
}

sub _client_failure ( $self, $result, $status ) {
    if ( $status eq 'invalid' ) {
        return $self->_bad_request( $result->{errors} );
    }
    if ( $status eq 'conflict' ) {
        return $self->_conflict( $result->{error} );
    }

    return;
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

sub command_id_param ($self) {
    my $command_id = $self->_trim( $self->param('command_id') );
    if ( length $command_id ) {
        return $command_id;
    }

    return $self->_trim( $self->param('idempotency_key') );
}

sub optional_param ( $self, $name ) {
    my $value = $self->_trim( $self->param($name) );
    my $optional;
    if ( length $value ) {
        $optional = $value;
    }

    return $optional;
}

sub _allowed ( $self, $user_id ) {
    my $decision = $self->gp_rate_limiter->check(
        $self->moderation_access->write_rate_input(
            {
                action   => $self->moderation_access->write_action,
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
    $self->_set_success_flash(
        $self->moderation_access->write_flash_key($status) );

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
        $self->moderation_access->invalid_request($errors) );
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
L</write_permission_scope>.

=head2 authorized_user_id

Requires an authenticated actor with the requested moderation permission at
global scope. Read routes address no single resource, so they deliberately
pass L</global_permission_scope>.

=head2 global_permission_scope

Returns the explicit unscoped permission scope: both C<resource_id> and
C<space_id> undefined. L<GPForum::Service::Admin::PermissionGate> then
accepts global role bindings only.

=head2 write_permission_scope

Returns the permission scope for a write against the given permission
resource type. The resource id comes from the route placeholder that names
the acted-on row (C<post_id>, C<thread_id>, C<report_id>, C<action_id>,
C<suspension_id>, or C<user_id>), read from the stash so query and body
parameters cannot widen a scoped role binding. Resource types with no
matching placeholder fall back to L</global_permission_scope>.

=head2 command_id_param

Reads the submitted C<command_id>, falling back to C<idempotency_key>
like L<GPForum::Controller::Forum::Base>.

=head2 write_failure

Maps workflow statuses to HTTP error responses.

=head1 DIAGNOSTICS

HTTP errors are rendered as JSON or HTML depending on the request.

=head1 CONFIGURATION AND ENVIRONMENT

Uses permission and moderation helpers registered during application startup.

=head1 DEPENDENCIES

Uses L<Mojolicious::Controller>, L<GPForum::Web::Access>,
L<GPForum::Web::Guard>, L<GPForum::Web::ModerationAccess>, and
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
