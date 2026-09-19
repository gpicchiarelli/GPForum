package GPForum::Controller::Privacy::Base;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'Mojolicious::Controller';

use GPForum::Web::Access;
use GPForum::Web::Guard;
use GPForum::Web::PrivacyAccess;
use GPForum::Web::Responder;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

sub privacy_access {
    return GPForum::Web::PrivacyAccess->new;
}

sub limit_param {
    my ($self) = @_;

    return $self->privacy_access->page_limit( $self->param('limit') );
}

sub member_user_id {
    my ($self) = @_;

    my $user_id = $self->_current_user_id;
    if ( !$user_id ) {
        $self->_unauthorized;
        return;
    }

    return $user_id;
}

sub write_user_id {
    my ($self) = @_;

    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        $self->_csrf_failure;
        return;
    }

    return $self->member_user_id;
}

sub authorized_write_user_id {
    my ($self) = @_;

    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        $self->_csrf_failure;
        return;
    }

    return $self->authorized_user_id( $self->privacy_access->manage_action );
}

sub authorized_user_id {
    my ( $self, $action ) = @_;

    my $user_id = $self->member_user_id;
    if ( !$user_id ) {
        return;
    }
    if ( !$self->_permission_allowed( $user_id, $action ) ) {
        $self->_forbidden;
        return;
    }

    return $user_id;
}

sub export_write_response {
    my ( $self, $result ) = @_;

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

sub deletion_write_response {
    my ( $self, $result ) = @_;

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

sub deletion_review_write_response {
    my ( $self, $result, $ok_status ) = @_;

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

sub erasure_write_response {
    my ( $self, $result ) = @_;

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

sub write_failure {
    my ( $self, $result ) = @_;

    if ( $self->privacy_access->is_failed($result) ) {
        return $self->_system_failure;
    }

    return $self->_mapped_failure($result);
}

sub privacy_action_response {
    my ( $self, $payload, $redirect_route ) = @_;

    if ( $self->_wants_json ) {
        return $self->render(
            json   => $payload,
            status => $HTTP_OK,
        );
    }

    return $self->redirect_to( $redirect_route
          || $self->privacy_access->default_redirect );
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

sub _mapped_failure {
    my ( $self, $result ) = @_;

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

sub _permission_allowed {
    my ( $self, $user_id, $action ) = @_;

    return $self->gp_permission_gate->allowed( { user_id => $user_id },
        $self->privacy_access->permission_target($action) );
}

sub _current_user_id {
    my ($self) = @_;

    return GPForum::Web::Access->new->user_id($self);
}

sub _wants_json {
    my ($self) = @_;

    return GPForum::Web::Access->new->wants_json($self);
}

sub _bad_request {
    my ( $self, $errors ) = @_;

    return GPForum::Web::Guard->new->bad_request( $self,
        $self->privacy_access->invalid_request($errors) );
}

sub _csrf_failure {
    my ($self) = @_;

    return GPForum::Web::Guard->new->csrf_failure($self);
}

sub _unauthorized {
    my ($self) = @_;

    return GPForum::Web::Guard->new->unauthorized($self);
}

sub _forbidden {
    my ($self) = @_;

    return GPForum::Web::Guard->new->forbidden($self);
}

sub _not_found {
    my ( $self, $error ) = @_;

    return GPForum::Web::Guard->new->not_found( $self, $error );
}

sub _conflict {
    my ( $self, $error ) = @_;

    return GPForum::Web::Guard->new->conflict( $self,
        $self->privacy_access->conflict_payload($error) );
}

sub _system_failure {
    my ($self) = @_;

    return GPForum::Web::Guard->new->system_failure($self);
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

Owns CSRF, authorization, and Guard errors used by member privacy and staff
review controllers. Page limits, permission-target hashes, conflict
payloads, and failure-status mapping live on
L<GPForum::Web::PrivacyAccess>.

=head1 SUBROUTINES/METHODS

=head2 write_user_id

Rejects invalid CSRF tokens and anonymous member writes.

=head2 authorized_write_user_id

Rejects invalid CSRF tokens and unauthorized staff writes.

=head2 authorized_user_id

Requires an authenticated actor with the requested privacy permission.

=head2 write_failure

Maps workflow statuses to HTTP error responses.

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
