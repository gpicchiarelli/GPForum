# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Notifications::Base;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use GPForum::Web::Access;
use GPForum::Web::Guard;
use GPForum::Web::NotificationAccess;
use GPForum::Web::Responder;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_TOO_MANY     => 429;

sub notification_access {
    return GPForum::Web::NotificationAccess->new;
}

sub member_user_id ($self) {
    my $user_id = $self->_current_user_id;
    if ( !$user_id ) {
        $self->_unauthorized;
        my $undefined;
        return $undefined;
    }

    return $user_id;
}

sub write_user_id ( $self, $action ) {
    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        $self->_csrf_failure;
        my $undefined;
        return $undefined;
    }

    return $self->_rate_limited_user_id($action);
}

sub page_limit ($self) {
    return $self->notification_access->page_limit( $self->param('limit') );
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

sub mark_read_response ( $self, $result ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->_mark_read_success( $result->{stored} );
}

sub mark_all_read_response ( $self, $result ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->_mark_all_read_success( $result->{stored} );
}

sub write_failure ( $self, $result ) {
    if ( $self->notification_access->is_failed($result) ) {
        return $self->_system_failure;
    }

    return $self->_mapped_failure($result);
}

sub _rate_limited_user_id ( $self, $action ) {
    my $undefined;

    my $user_id = $self->member_user_id;
    if ( !$user_id ) {
        return $undefined;
    }
    if ( !$self->_allowed( $user_id, $action ) ) {
        $self->_rate_limited;
        return $undefined;
    }

    return $user_id;
}

sub _mark_read_success ( $self, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json =>
              $self->gp_notifications_view_model->mark_read_response($stored),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $self->notification_access->marked_read_status,
        'notifications', );
}

sub _mark_all_read_success ( $self, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_notifications_view_model->mark_all_read_response(
                $stored),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success(
        $self->notification_access->marked_all_read_status,
        'notifications', );
}

sub _mapped_failure ( $self, $result ) {
    my $status = $self->notification_access->failure_status($result) || q{};
    if ( $status eq 'not_found' ) {
        return $self->_not_found( $result->{error} );
    }

    my $undefined;
    return $undefined;
}

sub _allowed ( $self, $user_id, $action ) {
    my $decision = $self->gp_rate_limiter->check(
        $self->notification_access->write_rate_input(
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
        $self->notification_access->write_flash_key($status) );

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

sub _system_failure ($self) {
    return GPForum::Web::Guard->new->system_failure($self);
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
    return eval { return $self->current_route; } || 'unknown';
}

1;

__END__

=head1 NAME

GPForum::Controller::Notifications::Base - Shared notification HTTP helpers.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use Mojo::Base 'GPForum::Controller::Notifications::Base';

=head1 DESCRIPTION

Owns CSRF, authentication, Guard errors, telemetry, and response helpers
used by inbox, mention, and mark-read controllers. Page limits, write
rate-limit hashes, and failure-status mapping live on
L<GPForum::Web::NotificationAccess>.

=head1 SUBROUTINES/METHODS

=head2 member_user_id

Requires an authenticated member for inbox and mention reads.

=head2 write_user_id

Rejects invalid CSRF tokens, anonymous writes, and rate-limited actors.

=head2 write_failure

Maps workflow statuses to HTTP error responses.

=head2 mark_read_response

Renders a successful mark-read as JSON or an inbox redirect.

=head2 mark_all_read_response

Renders a successful mark-all-read as JSON or an inbox redirect.

=head1 DIAGNOSTICS

HTTP errors are rendered as JSON or HTML depending on the request. CSRF, auth,
and rate-limit denials record security telemetry before rendering.

=head1 CONFIGURATION AND ENVIRONMENT

Uses notification, rate-limit, and telemetry helpers registered during
application startup.

=head1 DEPENDENCIES

Uses L<Mojolicious::Controller>, L<GPForum::Web::Access>,
L<GPForum::Web::Guard>, L<GPForum::Web::NotificationAccess>, and
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
