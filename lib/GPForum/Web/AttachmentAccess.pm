# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::AttachmentAccess;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

const my $UPLOAD_ACTION    => 'attachment.upload';
const my $UPLOAD_LIMIT     => 20;
const my $UPLOAD_WINDOW    => 60;
const my $DOWNLOAD_ACTION  => 'attachment.download';
const my $DOWNLOAD_LIMIT   => 120;
const my $DOWNLOAD_WINDOW  => 60;
const my $DEFAULT_FILENAME => 'attachment';
const my $STATUS_CONFLICT  => 'conflict';
const my $STATUS_FAILED    => 'failed';
const my $STATUS_NOT_FOUND => 'not_found';
const my $STATUS_INVALID   => 'invalid';
const my $STATUS_FORBIDDEN => 'forbidden';
const my $STATUS_UPLOADED  => 'uploaded';
const my $STATUS_DELETED   => 'deleted';
const my %WRITE_FLASH => (
    $STATUS_DELETED  => 'forum.attachment_deleted',
    $STATUS_UPLOADED => 'forum.attachment_uploaded',
);

sub upload_rate_input ( $, $user_id ) {
    return {
        action         => $UPLOAD_ACTION,
        actor_id       => $user_id,
        limit          => $UPLOAD_LIMIT,
        scope          => 'forum_http',
        window_seconds => $UPLOAD_WINDOW,
    };
}

# Download was the one attachment route with no bucket at all. It is reachable
# without a session, so the key falls back to the peer address: a logged-in
# actor is limited as themselves, everyone else per address.
sub download_rate_input ( $, $actor_key ) {
    return {
        action         => $DOWNLOAD_ACTION,
        actor_id       => $actor_key,
        limit          => $DOWNLOAD_LIMIT,
        scope          => 'forum_http',
        window_seconds => $DOWNLOAD_WINDOW,
    };
}

sub safe_filename ( $, $filename ) {
    if ( !defined $filename || !length $filename ) {
        $filename = $DEFAULT_FILENAME;
    }
    $filename =~ s/["\r\n]/_/gmsx;

    return $filename;
}

sub content_disposition ( $self, $filename ) {
    return 'attachment; filename="' . $self->safe_filename($filename) . q{"};
}

sub is_failed ( $self, $result ) {
    return $self->_status($result) eq $STATUS_FAILED ? 1 : 0;
}

sub failure_status ( $self, $result ) {
    my $status = $self->_status($result);
    if ( $status eq $STATUS_NOT_FOUND ) {
        return $status;
    }
    if ( $status eq $STATUS_INVALID ) {
        return $status;
    }
    if ( $status eq $STATUS_FORBIDDEN ) {
        return $status;
    }
    if ( $status eq $STATUS_CONFLICT ) {
        return $STATUS_INVALID;
    }

    return undef;
}

sub invalid_request ( $, $errors ) {
    return {
        error  => 'The submitted attachment was invalid.',
        errors => $errors || {},
        title  => 'Invalid attachment',
    };
}

sub rate_limited_payload {
    return {
        error => 'rate limit exceeded',
        title => 'Rate limited',
    };
}

sub uploaded_status {
    return $STATUS_UPLOADED;
}

sub deleted_status {
    return $STATUS_DELETED;
}

sub write_flash_key ( $, $status ) {
    if ( !defined $status ) {
        return undef;
    }
    if ( exists $WRITE_FLASH{$status} ) {
        return $WRITE_FLASH{$status};
    }

    return undef;
}

sub _status ( $, $result ) {
    return $result->{status} || q{};
}

1;

__END__

=head1 NAME

GPForum::Web::AttachmentAccess - Attachment rate limits and HTTP policy.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $access   = GPForum::Web::AttachmentAccess->new;
    my $upload   = $access->upload_rate_input($user_id);
    my $download = $access->download_rate_input($actor_key);
    my $header   = $access->content_disposition( $attachment->{filename} );

=head1 DESCRIPTION

Owns the attachment upload and download rate-limit hashes, download
filename sanitizing, content-disposition values, workflow failure status
mapping, and Guard payloads for invalid uploads and rate limits. It does
not render HTTP responses or load attachments.
L<GPForum::Controller::Attachments::Base> still checks CSRF, sessions, and
Guard errors.

=head1 SUBROUTINES/METHODS

=head2 upload_rate_input

Takes a user id. Returns the C<forum_http> rate-limit arguments for
C<attachment.upload>: 20 uploads per 60 seconds for that user.

=head2 download_rate_input

Takes the actor key to limit: the controller passes the user id when there
is a session and C<address:> with the peer address otherwise, since
downloads are reachable without one. Returns the C<forum_http> rate-limit
arguments for C<attachment.download>: 120 downloads per 60 seconds for
that key.

=head2 safe_filename

Takes a filename. Returns it with each double quote, carriage return and
line feed replaced by an underscore, or C<attachment> when it is undef or
empty.

=head2 content_disposition

Takes a filename. Returns the C<Content-Disposition> header value,
C<attachment; filename="..."> with the name made safe by
C<safe_filename>.

=head2 is_failed

Takes a workflow result hash reference. Returns 1 when its status is
C<failed>, else 0.

=head2 failure_status

Takes a workflow result hash reference. Returns its status when it is
C<not_found>, C<invalid> or C<forbidden>, C<invalid> for C<conflict>, and
undef for any other status.

=head2 invalid_request

Takes the validation errors hash reference (or undef). Returns the Guard
bad-request payload for an invalid upload: C<error>, C<title> and
C<errors> (an empty hash when none were given).

=head2 rate_limited_payload

Returns the Guard rate-limit payload used by attachment HTTP.

=head2 uploaded_status

Returns C<uploaded>.

=head2 deleted_status

Returns C<deleted>.

=head2 write_flash_key

Takes a write status. Returns the i18n catalog key for a successful HTML
write (C<forum.attachment_uploaded> or C<forum.attachment_deleted>), or
undef when the status has no flash copy.

=head1 DIAGNOSTICS

None. HTTP rendering stays on the attachment controllers.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

CSRF, authentication, and Guard rendering remain on
L<GPForum::Controller::Attachments::Base>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
