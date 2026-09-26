# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Attachments::Base;

use strict;
use warnings;

use Const::Fast;
use Mojo::Asset::File;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use GPForum::Web::Access;
use GPForum::Web::AttachmentAccess;
use GPForum::Web::Guard;

our $VERSION = '0.001';

const my $HTTP_OK        => 200;
const my $LAST_CHARACTER => -1;
const my $HTTP_CREATED   => 201;

sub attachment_access {
    return GPForum::Web::AttachmentAccess->new;
}

sub write_user_id ($self) {
    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        $self->_csrf_failure;
        my $undefined;
        return $undefined;
    }

    return $self->_rate_limited_user_id;
}

sub current_user_id ($self) {
    return GPForum::Web::Access->new->user_id($self);
}

sub wants_json ($self) {
    return GPForum::Web::Access->new->wants_json($self);
}

sub column ( $self, $row, $name ) {
    if ( !$row ) {
        my $undefined;
        return $undefined;
    }
    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }

    return $self->_object_column( $row, $name );
}

sub safe_filename ( $self, $filename ) {
    return $self->attachment_access->safe_filename($filename);
}

sub upload_write_response ( $self, $result ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->upload_response( $result->{stored} );
}

sub delete_write_response ( $self, $result ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->delete_response( $result->{stored} );
}

sub download_response ( $self, $result ) {
    my $failure = $self->write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->render_download( $result->{stored} );
}

sub write_failure ( $self, $result ) {
    if ( $self->attachment_access->is_failed($result) ) {
        return $self->_unavailable;
    }

    return $self->_mapped_failure($result);
}

sub upload_response ( $self, $stored ) {
    if ( $self->wants_json ) {
        return $self->_upload_json($stored);
    }

    return $self->_upload_redirect($stored);
}

sub delete_response ( $self, $stored ) {
    if ( $self->wants_json ) {
        return $self->_delete_json($stored);
    }

    return $self->_delete_redirect($stored);
}

# Three ways out, cheapest first. Behind a reverse proxy that accepts the
# hand-off, the bytes never enter this process at all. Otherwise Mojolicious
# serves the file as an asset, which streams it and answers Range requests
# instead of building one big response body. render(data => ...) is the last
# resort and now only reachable from a storage backend that cannot name a path.
sub render_download ( $self, $stored ) {
    $self->res->headers->content_type( $stored->{media_type} );
    $self->res->headers->content_disposition(
        $self->attachment_access->content_disposition(
            $stored->{original_filename}
        )
    );

    my $delegated = $self->_delegated_download($stored);
    return $delegated if $delegated;

    if ( defined $stored->{object_path} ) {
        return $self->reply->asset(
            Mojo::Asset::File->new( path => $stored->{object_path} ) );
    }

    return $self->render( data => $stored->{content}, status => $HTTP_OK );
}

# deploy/nginx/gpforum.conf has shipped the internal /internal-attachments/
# alias since before anything emitted the header for it, and
# GPForum::OS::RuntimeEvidence recorded x_accel_redirect_implemented => 0.
# Empty configuration keeps it off, which is the only safe default: a proxy
# that does not understand the header would send it to the client.
sub _delegated_download ( $self, $stored ) {
    my $prefix = $self->_accel_prefix;
    my $undefined;
    return $undefined if !length $prefix;
    return $undefined if !defined $stored->{object_key};

    # The key reaches a response header, so it is checked here rather than
    # trusted. FilesystemStorage::path_for already refuses anything outside
    # this set, but that only guards the backends that implement path_for:
    # a CR or LF arriving from a row would otherwise be header injection.
    ## no critic (RegularExpressions::ProhibitEnumeratedClasses)
    # The enumeration is the point: this is a whitelist of what may
    # appear in a header value, and \w would admit more than that.
    return $undefined if $stored->{object_key} =~ m{[^A-Za-z0-9._/\-]}msx;
    ## use critic

    $self->res->headers->header(
        'X-Accel-Redirect' => $prefix . $stored->{object_key} );

    return $self->rendered($HTTP_OK);
}

sub _accel_prefix ($self) {
    my $prefix = $self->gp_config->attachment_accel_redirect;
    return q{} if !defined $prefix || !length $prefix;

    if ( substr( $prefix, $LAST_CHARACTER ) ne q{/} ) {
        $prefix .= q{/};
    }

    return $prefix;
}

sub download_rate_failure ($self) {
    my $decision = $self->gp_rate_limiter->check(
        $self->attachment_access->download_rate_input(
            $self->download_actor_key
        )
    );
    return $self->_rate_limited if !$decision->{ok};

    my $undefined;
    return $undefined;
}

sub download_actor_key ($self) {
    my $user_id = $self->current_user_id;
    return $user_id if defined $user_id && length $user_id;

    return 'address:' . ( $self->tx->remote_address || 'unknown' );
}

sub _rate_limited_user_id ($self) {
    my $undefined;

    my $user_id = $self->current_user_id;
    if ( !$user_id ) {
        $self->_unauthorized;
        return $undefined;
    }
    if ( !$self->_upload_allowed($user_id) ) {
        $self->_rate_limited;
        return $undefined;
    }

    return $user_id;
}

sub _upload_allowed ( $self, $user_id ) {
    my $decision = $self->gp_rate_limiter->check(
        $self->attachment_access->upload_rate_input($user_id) );

    return $decision->{ok};
}

sub _upload_json ( $self, $stored ) {
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

sub _upload_redirect ( $self, $stored ) {
    return $self->_post_redirect( $stored,
        $self->attachment_access->uploaded_status );
}

sub _delete_json ( $self, $stored ) {
    return $self->render(
        json   => $self->gp_attachment_view_model->delete_response($stored),
        status => $HTTP_OK,
    );
}

sub _delete_redirect ( $self, $stored ) {
    return $self->_post_redirect( $stored,
        $self->attachment_access->deleted_status );
}

sub _post_redirect ( $self, $stored, $status ) {
    my $thread_id = $self->column( $stored->{post}, 'thread_id' );

    return $self->_html_success(
        $status,
        $self->url_for( 'thread', thread_id => $thread_id )
          ->fragment( 'post-' . $self->param('post_id') ),
    );
}

sub _html_success ( $self, $status, $location ) {
    $self->_set_success_flash(
        $self->attachment_access->write_flash_key($status) );

    return $self->redirect_to($location);
}

sub _set_success_flash ( $self, $flash_key ) {
    if ( !$flash_key ) {
        return;
    }

    $self->flash( success => $self->t($flash_key) );

    return;
}

sub _mapped_failure ( $self, $result ) {
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

    my $undefined;
    return $undefined;
}

sub _object_column ( $self, $row, $name ) {
    if ( $row->can('get_column') ) {
        return $row->get_column($name);
    }

    my $undefined;
    return $undefined;
}

sub _bad_request ( $self, $errors ) {
    return GPForum::Web::Guard->new->bad_request( $self,
        $self->attachment_access->invalid_request($errors) );
}

sub _csrf_failure ($self) {
    return GPForum::Web::Guard->new->csrf_failure($self);
}

sub _unauthorized ($self) {
    return GPForum::Web::Guard->new->unauthorized($self);
}

sub _forbidden ( $self, $error ) {
    return GPForum::Web::Guard->new->forbidden(
        $self,
        {
            error => $error,
        }
    );
}

sub _not_found ( $self, $error ) {
    return GPForum::Web::Guard->new->not_found( $self, $error );
}

sub _rate_limited ($self) {
    return GPForum::Web::Guard->new->rate_limited( $self,
        $self->attachment_access->rate_limited_payload,
    );
}

sub command_id_param ($self) {
    my $command_id = $self->param('command_id');
    if ( !defined $command_id ) {
        $command_id = q{};
    }
    $command_id =~ s/\A \s+//msx;
    $command_id =~ s/\s+ \z//msx;

    return $command_id;
}

sub _unavailable ($self) {
    return GPForum::Web::Guard->new->service_unavailable($self);
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

Maps workflow statuses to HTTP error responses. Store and command-log
failures use HTTP 503.

=head2 upload_write_response

Renders a successful upload as JSON or a thread redirect.

=head2 delete_write_response

Renders a successful author delete as JSON or a thread redirect.

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
