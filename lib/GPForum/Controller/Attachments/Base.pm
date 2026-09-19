package GPForum::Controller::Attachments::Base;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'Mojolicious::Controller';

use GPForum::Web::Access;
use GPForum::Web::AttachmentAccess;
use GPForum::Web::Guard;

our $VERSION = '0.001';

const my $HTTP_OK      => 200;
const my $HTTP_CREATED => 201;

sub attachment_access {
    return GPForum::Web::AttachmentAccess->new;
}

sub write_user_id {
    my ($self) = @_;

    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        $self->_csrf_failure;
        return;
    }

    return $self->_rate_limited_user_id;
}

sub current_user_id {
    my ($self) = @_;

    return GPForum::Web::Access->new->user_id($self);
}

sub wants_json {
    my ($self) = @_;

    return GPForum::Web::Access->new->wants_json($self);
}

sub column {
    my ( $self, $row, $name ) = @_;

    if ( !$row ) {
        return;
    }
    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }

    return $self->_object_column( $row, $name );
}

sub safe_filename {
    my ( $self, $filename ) = @_;

    return $self->attachment_access->safe_filename($filename);
}

sub upload_write_response {
    my ( $self, $result ) = @_;

    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->upload_response( $result->{stored} );
}

sub download_response {
    my ( $self, $result ) = @_;

    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->render_download( $result->{stored} );
}

sub write_failure {
    my ( $self, $result ) = @_;

    if ( $self->attachment_access->is_failed($result) ) {
        return $self->_system_failure;
    }

    return $self->_mapped_failure($result);
}

sub upload_response {
    my ( $self, $stored ) = @_;

    if ( $self->wants_json ) {
        return $self->_upload_json($stored);
    }

    return $self->_upload_redirect($stored);
}

sub render_download {
    my ( $self, $stored ) = @_;

    $self->res->headers->content_type( $stored->{media_type} );
    $self->res->headers->content_disposition(
        $self->attachment_access->content_disposition(
            $stored->{original_filename}
        )
    );

    return $self->render( data => $stored->{content}, status => $HTTP_OK );
}

sub _rate_limited_user_id {
    my ($self) = @_;

    my $user_id = $self->current_user_id;
    if ( !$user_id ) {
        $self->_unauthorized;
        return;
    }
    if ( !$self->_upload_allowed($user_id) ) {
        $self->_rate_limited;
        return;
    }

    return $user_id;
}

sub _upload_allowed {
    my ( $self, $user_id ) = @_;

    my $decision = $self->gp_rate_limiter->check(
        $self->attachment_access->upload_rate_input($user_id) );

    return $decision->{ok};
}

sub _upload_json {
    my ( $self, $stored ) = @_;

    my $download_url = $self->url_for( 'attachment_download',
        attachment_id =>
          $self->column( $stored->{attachment}, 'attachment_id' ), )->to_string;

    return $self->render(
        json => $self->gp_attachment_view_model->upload_response(
            $stored, download_url => $download_url,
        ),
        status => $HTTP_CREATED,
    );
}

sub _upload_redirect {
    my ( $self, $stored ) = @_;

    my $thread_id = $self->column( $stored->{post}, 'thread_id' );

    return $self->redirect_to(
        $self->url_for( 'thread', thread_id => $thread_id )
          ->fragment( 'post-' . $self->param('post_id') ) );
}

sub _mapped_failure {
    my ( $self, $result ) = @_;

    my $status = $self->attachment_access->failure_status($result) || q{};
    if ( $status eq 'not_found' ) {
        return $self->_not_found( $result->{error} );
    }
    if ( $status eq 'invalid' ) {
        return $self->_bad_request( $result->{errors} );
    }
    if ( $status eq 'forbidden' ) {
        return $self->_forbidden( $result->{error} );
    }

    return;
}

sub _object_column {
    my ( $self, $row, $name ) = @_;

    if ( $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return;
}

sub _bad_request {
    my ( $self, $errors ) = @_;

    return GPForum::Web::Guard->new->bad_request( $self,
        $self->attachment_access->invalid_request($errors) );
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
    my ( $self, $error ) = @_;

    return GPForum::Web::Guard->new->forbidden(
        $self,
        {
            error => $error,
        }
    );
}

sub _not_found {
    my ( $self, $error ) = @_;

    return GPForum::Web::Guard->new->not_found( $self, $error );
}

sub _rate_limited {
    my ($self) = @_;

    return GPForum::Web::Guard->new->rate_limited( $self,
        $self->attachment_access->rate_limited_payload,
    );
}

sub _system_failure {
    my ($self) = @_;

    return GPForum::Web::Guard->new->system_failure($self);
}

1;

__END__

=head1 NAME

GPForum::Controller::Attachments::Base - Shared attachment HTTP helpers.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use Mojo::Base 'GPForum::Controller::Attachments::Base';

=head1 DESCRIPTION

Owns CSRF, authentication, Guard errors, and response helpers used by
attachment download and upload controllers. Upload rate-limit hashes,
filename sanitizing, and failure-status mapping live on
L<GPForum::Web::AttachmentAccess>.

=head1 SUBROUTINES/METHODS

=head2 write_user_id

Rejects invalid CSRF tokens, anonymous uploads, and rate-limited actors.

=head2 write_failure

Maps workflow statuses to HTTP error responses.

=head2 upload_write_response

Renders a successful upload as JSON or a thread redirect.

=head2 download_response

Streams attachment bytes after a successful delivery lookup.

=head1 DIAGNOSTICS

HTTP errors are rendered as JSON or HTML depending on the request.

=head1 CONFIGURATION AND ENVIRONMENT

Uses attachment, post, and rate-limit helpers registered during application
startup.

=head1 DEPENDENCIES

Uses L<Mojolicious::Controller>, L<GPForum::Web::Access>,
L<GPForum::Web::AttachmentAccess>, and L<GPForum::Web::Guard>.

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
