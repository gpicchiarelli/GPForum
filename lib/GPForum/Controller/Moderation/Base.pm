package GPForum::Controller::Moderation::Base;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'Mojolicious::Controller';

use GPForum::Web::Access;
use GPForum::Web::Guard;
use GPForum::Web::ModerationAccess;
use GPForum::Web::Responder;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_TOO_MANY     => 429;

sub moderation_access {
    return GPForum::Web::ModerationAccess->new;
}

sub queue_limit {
    my ($self) = @_;

    return $self->moderation_access->queue_limit( $self->param('limit') );
}

sub authorized_write_user_id {
    my ( $self, $resource_type, $action ) = @_;

    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        $self->_csrf_failure;
        return;
    }

    my $user_id = $self->authorized_user_id( $resource_type, $action );
    if ( !$user_id ) {
        return;
    }
    if ( !$self->_allowed($user_id) ) {
        $self->_rate_limited;
        return;
    }

    return $user_id;
}

sub authorized_user_id {
    my ( $self, $resource_type, $action ) = @_;

    my $decision =
      $self->moderation_access->authorization_target( $resource_type, $action );
    my $user_id = $self->_current_user_id;
    if ( !$user_id ) {
        $self->_unauthorized;
        return;
    }
    if ( !$self->_permission_allowed( $user_id, $decision ) ) {
        $self->_forbidden;
        return;
    }

    return $user_id;
}

sub report_write_response {
    my ( $self, $result, $ok_status ) = @_;

    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->action_response( $ok_status, $result->{stored} );
}

sub moderation_write_response {
    my ( $self, $result, $ok_status ) = @_;

    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->moderation_action_response( $ok_status, $result->{stored} );
}

sub suspension_write_response {
    my ( $self, $result, $ok_status ) = @_;

    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->suspension_response( $ok_status, $result->{stored} );
}

sub write_failure {
    my ( $self, $result ) = @_;

    if ( $self->moderation_access->is_failed($result) ) {
        return $self->_service_unavailable;
    }

    return $self->_mapped_failure($result);
}

sub _mapped_failure {
    my ( $self, $result ) = @_;

    my $status = $self->moderation_access->failure_status($result) || q{};
    if ( $status eq 'not_found' ) {
        return $self->_not_found( $result->{error} );
    }

    return $self->_client_failure( $result, $status );
}

sub _client_failure {
    my ( $self, $result, $status ) = @_;

    if ( $status eq 'invalid' ) {
        return $self->_bad_request( $result->{errors} );
    }
    if ( $status eq 'conflict' ) {
        return $self->_conflict( $result->{error} );
    }

    return;
}

sub _conflict {
    my ( $self, $error ) = @_;

    return GPForum::Web::Guard->new->conflict(
        $self,
        {
            error => $error || 'idempotency conflict',
            title => 'Conflict',
        }
    );
}

sub moderation_action_response {
    my ( $self, $status, $action ) = @_;

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

sub suspension_response {
    my ( $self, $status, $suspension ) = @_;

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

sub action_response {
    my ( $self, $status, $report ) = @_;

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

sub render_payload {
    my ( $self, $input ) = @_;

    return GPForum::Web::Responder->new->payload(
        {
            controller => $self,
            payload    => $input->{payload},
            status     => $input->{status},
            template   => $input->{template},
        }
    );
}

sub status_param {
    my ($self) = @_;

    return $self->moderation_access->queue_status(
        $self->_trim( $self->param('status') ) );
}

sub suspension_status_param {
    my ($self) = @_;

    return $self->moderation_access->suspension_status(
        $self->_trim( $self->param('status') ) );
}

sub reason_param {
    my ($self) = @_;

    return $self->_trim( $self->param('reason') );
}

sub command_id_param {
    my ($self) = @_;

    my $command_id = $self->_trim( $self->param('command_id') );
    if ( length $command_id ) {
        return $command_id;
    }

    return $self->_trim( $self->param('idempotency_key') );
}

sub optional_param {
    my ( $self, $name ) = @_;

    my $value = $self->_trim( $self->param($name) );
    my $optional;
    if ( length $value ) {
        $optional = $value;
    }

    return $optional;
}

sub _permission_allowed {
    my ( $self, $user_id, $decision ) = @_;

    return $self->gp_permission_gate->allowed(
        { user_id => $user_id },
        {
            resource_type => $decision->{resource_type},
            action        => $decision->{action},
        }
    );
}

sub _allowed {
    my ( $self, $user_id ) = @_;

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

sub _current_user_id {
    my ($self) = @_;

    return GPForum::Web::Access->new->user_id($self);
}

sub _html_success {
    my ( $self, $status, $route ) = @_;

    $self->_set_success_flash(
        $self->moderation_access->write_flash_key($status) );

    return $self->redirect_to($route);
}

sub _set_success_flash {
    my ( $self, $flash_key ) = @_;

    if ( !$flash_key ) {
        return;
    }

    $self->flash( success => $self->t($flash_key) );

    return;
}

sub _wants_json {
    my ($self) = @_;

    return GPForum::Web::Access->new->wants_json($self);
}

sub _trim {
    my ( undef, $value ) = @_;

    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _bad_request {
    my ( $self, $errors ) = @_;

    return GPForum::Web::Guard->new->bad_request( $self,
        $self->moderation_access->invalid_request($errors) );
}

sub _csrf_failure {
    my ($self) = @_;

    $self->_record_security_event(
        'csrf_failure',
        {
            status => $HTTP_FORBIDDEN,
        }
    );

    return GPForum::Web::Guard->new->csrf_failure($self);
}

sub _unauthorized {
    my ($self) = @_;

    $self->_record_security_event(
        'auth_denial',
        {
            status => $HTTP_UNAUTHORIZED,
        }
    );

    return GPForum::Web::Guard->new->unauthorized($self);
}

sub _forbidden {
    my ($self) = @_;

    $self->_record_security_event(
        'auth_denial',
        {
            reason => 'forbidden',
            status => $HTTP_FORBIDDEN,
        }
    );

    return GPForum::Web::Guard->new->forbidden($self);
}

sub _rate_limited {
    my ($self) = @_;

    $self->_record_security_event(
        'rate_limit_hit',
        {
            status => $HTTP_TOO_MANY,
        }
    );

    return GPForum::Web::Guard->new->rate_limited($self);
}

sub _not_found {
    my ( $self, $error ) = @_;

    return GPForum::Web::Guard->new->not_found( $self, $error );
}

sub system_failure {
    my ($self) = @_;

    return GPForum::Web::Guard->new->system_failure($self);
}

sub _service_unavailable {
    my ($self) = @_;

    return GPForum::Web::Guard->new->service_unavailable($self);
}

sub _record_security_event {
    my ( $self, $event_type, $metadata ) = @_;

    return $self->gp_security_telemetry->record(
        $event_type,
        {
            %{$metadata}, route => $self->_current_route_name,
        }
    );
}

sub _current_route_name {
    my ($self) = @_;

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
rate-limited actors.

=head2 authorized_user_id

Requires an authenticated actor with the requested moderation permission.

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
