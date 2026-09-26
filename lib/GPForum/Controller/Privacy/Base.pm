# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Privacy::Base;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use GPForum::Web::Access;
use GPForum::Web::Guard;
use GPForum::Web::PrivacyAccess;
use GPForum::Web::Responder;

our $VERSION = '0.001';

const my $HTTP_OK       => 200;
const my $HTTP_TOO_MANY => 429;

sub privacy_access {
    return GPForum::Web::PrivacyAccess->new;
}

sub limit_param ($self) {
    return $self->privacy_access->page_limit( $self->param('limit') );
}

sub member_user_id ($self) {
    my $user_id = $self->_current_user_id;
    if ( !$user_id ) {
        $self->_unauthorized;
        return;
    }

    return $user_id;
}

sub command_id_param ($self) {
    my $command_id = $self->_trim( $self->param('command_id') );
    if ( length $command_id ) {
        return $command_id;
    }

    return $self->_trim( $self->param('idempotency_key') );
}

sub write_user_id ($self) {
    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        $self->_csrf_failure;
        return;
    }

    return $self->_rate_limited_user_id( $self->member_user_id,
        $self->privacy_access->request_action );
}

sub authorized_write_user_id ($self) {
    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        $self->_csrf_failure;
        return;
    }

    return $self->_rate_limited_user_id(
        $self->authorized_user_id( $self->privacy_access->manage_action ),
        $self->privacy_access->review_action,
    );
}

sub authorized_user_id ( $self, $action ) {
    my $user_id = $self->member_user_id;
    if ( !$user_id ) {
        return;
    }
    my $permission = {
        %{ $self->privacy_access->permission_target($action) },
        %{ $self->global_permission_scope },
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

sub export_write_response ( $self, $result ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->privacy_action_response(
        $self->gp_privacy_view_model->export_request_response(
            'export_requested', $result->{stored},
        ),
    );
}

sub deletion_write_response ( $self, $result ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->privacy_action_response(
        $self->gp_privacy_view_model->deletion_request_response(
            'deletion_requested', $result->{stored},
        ),
    );
}

sub deletion_review_write_response ( $self, $result, $ok_status ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->privacy_action_response(
        $self->gp_privacy_view_model->deletion_review_response(
            $ok_status, $result->{stored},
        ),
        'privacy_review',
    );
}

sub erasure_write_response ( $self, $result ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->privacy_action_response(
        $self->gp_privacy_view_model->erasure_job_response(
            'erasure_completed', $result->{stored},
        ),
        'privacy_review',
    );
}

sub write_failure ( $self, $result ) {
    if ( $self->privacy_access->is_failed($result) ) {
        return $self->_service_unavailable;
    }

    return $self->_mapped_failure($result);
}

sub privacy_action_response ( $self, $payload, $redirect_route = undef ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json   => $payload,
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $payload->{status},
        $redirect_route || $self->privacy_access->default_redirect,
    );
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

sub _mapped_failure ( $self, $result ) {
    my $status = $self->privacy_access->failure_status($result) || q{};
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

sub global_permission_scope {
    return {
        resource_id => undef,
        space_id    => undef,
    };
}

sub _rate_limited_user_id ( $self, $user_id, $action ) {
    if ( !$user_id ) {
        return;
    }
    if ( !$self->_allowed( $user_id, $action ) ) {
        $self->_rate_limited;
        return;
    }

    return $user_id;
}

sub _allowed ( $self, $user_id, $action ) {
    my $decision = $self->gp_rate_limiter->check(
        $self->privacy_access->write_rate_input(
            {
                action   => $action,
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
        $self->privacy_access->write_flash_key($status) );

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

sub _bad_request ( $self, $errors ) {
    return GPForum::Web::Guard->new->bad_request( $self,
        $self->privacy_access->invalid_request($errors) );
}

sub _csrf_failure ($self) {
    return GPForum::Web::Guard->new->csrf_failure($self);
}

sub _unauthorized ($self) {
    return GPForum::Web::Guard->new->unauthorized($self);
}

sub _forbidden ($self) {
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

sub render_export_download ( $self, $row ) {
    my $request_id = $self->_row_value( $row, 'export_request_id' );
    $self->res->headers->content_type('application/json; charset=UTF-8');
    $self->res->headers->content_disposition(
        $self->privacy_access->export_download_disposition($request_id) );

    return $self->render(
        json   => $self->_row_value( $row, 'manifest' ) || {},
        status => $HTTP_OK,
    );
}

sub _row_value ( $, $row, $name ) {
    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }
    if ( $row && $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return;
}

sub _not_found ( $self, $error ) {
    return GPForum::Web::Guard->new->not_found( $self, $error );
}

sub _conflict ( $self, $error ) {
    return GPForum::Web::Guard->new->conflict( $self,
        $self->privacy_access->conflict_payload($error) );
}

sub system_failure ($self) {
    return GPForum::Web::Guard->new->system_failure($self);
}

sub _service_unavailable ($self) {
    return GPForum::Web::Guard->new->service_unavailable($self);
}

sub _trim ( $, $value ) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

1;

__END__

=head1 NAME

GPForum::Controller::Privacy::Base - Shared privacy HTTP helpers.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use Mojo::Base 'GPForum::Controller::Privacy::Base';

=head1 DESCRIPTION

Owns CSRF, authorization, rate-limit checks, telemetry, and Guard errors
used by member privacy and staff review controllers. Page limits, write
rate-limit hashes, permission-target hashes, conflict payloads, and
failure-status mapping live on L<GPForum::Web::PrivacyAccess>.

=head1 SUBROUTINES/METHODS

=head2 write_user_id

Rejects invalid CSRF tokens, anonymous member writes, and rate-limited
actors.

=head2 authorized_write_user_id

Rejects invalid CSRF tokens, unauthorized staff writes, and rate-limited
actors.

=head2 authorized_user_id

Requires an authenticated actor with the requested privacy permission at
global scope.

=head2 global_permission_scope

Returns the explicit unscoped permission scope: both C<resource_id> and
C<space_id> undefined. Export, deletion, and erasure rights cover a whole
account and have no category or space dimension, so privacy checks pass this
scope on purpose and L<GPForum::Service::Admin::PermissionGate> accepts
global role bindings only.

=head2 write_failure

Maps workflow statuses to HTTP error responses.

=head2 command_id_param

Reads the submitted C<command_id>, falling back to C<idempotency_key>.

=head1 DIAGNOSTICS

HTTP errors are rendered as JSON or HTML depending on the request.

=head1 CONFIGURATION AND ENVIRONMENT

Uses permission and privacy helpers registered during application startup.

=head1 DEPENDENCIES

Uses L<Mojolicious::Controller>, L<GPForum::Web::Access>,
L<GPForum::Web::Guard>, L<GPForum::Web::PrivacyAccess>, and
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
