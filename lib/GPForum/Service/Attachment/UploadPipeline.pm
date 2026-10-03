# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::UploadPipeline;

use strict;
use warnings;

use Carp        qw(croak);
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base, -signatures;

use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::Store;
use GPForum::Service::Attachment::Validator;

our $VERSION = '0.001';

has intent_builder => sub {
    return GPForum::Service::Attachment::IntentBuilder->new;
};

# The system antivirus (GPForum::Infrastructure::Antivirus), or undef when the
# operator turned scanning off. ADR 0108.
has antivirus => undef;
has storage   => undef;
has store     => sub { return GPForum::Service::Attachment::Store->new; };
has validator => sub { return GPForum::Service::Attachment::Validator->new; };

sub upload_and_link ( $self, $input ) {
    my $content = _upload_content($input);
    return { ok => 0, errors => { attachment => 'attachment is required' } }
      if !defined $content || !length $content;

    my $sniffed   = $self->validator->sniff_media_type($content);
    my $validated = $self->validator->validate_upload(
        {
            byte_size          => length $content,
            checksum           => sha256_hex($content),
            content            => $content,
            media_type         => _client_media_type($input),
            original_filename  => _original_filename($input),
            owner_user_id      => $input->{actor_user_id},
            sniffed_media_type => $sniffed,
        }
    );
    return $validated if !$validated->{ok};

    my $intent = $self->intent_builder->build_intent( $validated->{values} );
    $self->storage->write_object( $intent->{object_key}, $content );

    my $created  = $self->store->create_intent($intent);
    my $uploaded = $self->store->mark_uploaded( $intent->{attachment_id} );
    my $scanned  = $self->_scan_at_upload( $intent->{attachment_id}, $content );
    my $link     = $self->_link_target( $input, $intent->{attachment_id} );

    return {
        ok         => 1,
        attachment => {
            %{$intent},
            media_type  => $validated->{values}{media_type},
            state       => $scanned->{state}       || $uploaded->{state},
            scan_status => $scanned->{scan_status} || 'pending',
        },
        created => $created,
        link    => $link,
    };
}

# The verdict the upload can reach by itself. With scanning off, the media
# type check that already passed is the whole verdict, and the row says so
# ('format-check'). With a fast scanner -- the system's clamd, a fraction of a
# second -- the bytes are scanned now, so the common case needs no wait. A
# slow scanner, or one that cannot answer, leaves the upload pending: the
# attachment worker scans it and the outbox retries until it can, and nothing
# pending is ever served.
sub _scan_at_upload ( $self, $attachment_id, $content ) {
    my $antivirus = $self->antivirus;
    if ( !$antivirus ) {
        return $self->store->record_scan(
            {
                actor_id      => 'format-check',
                attachment_id => $attachment_id,
                scan_engine   => 'format-check',
                scan_status   => 'clean',
            }
        );
    }
    return {} if !$antivirus->answers_immediately;

    my $verdict = $antivirus->within_request->scan($content);
    return {} if $verdict->{status} eq 'error';

    return $self->store->record_scan(
        {
            actor_id       => 'antivirus',
            attachment_id  => $attachment_id,
            reason         => _verdict_reason($verdict),
            scan_engine    => $verdict->{engine},
            scan_signature => $verdict->{signature},
            scan_status    => $verdict->{status},
        }
    );
}

sub _verdict_reason ($verdict) {
    return "malware: $verdict->{signature}" if $verdict->{status} eq 'infected';

    my $undefined;
    return $undefined;
}

sub _link_target ( $self, $input, $attachment_id ) {
    my $undefined;
    return $undefined if !_has_text( $input->{target_type} );
    return $undefined if !_has_text( $input->{target_id} );

    return $self->store->link_attachment(
        {
            attachment_id => $attachment_id,
            target_id     => $input->{target_id},
            target_type   => $input->{target_type},
        }
    );
}

sub _upload_content ($input) {
    return $input->{content} if defined $input->{content};

    my $upload = $input->{upload};
    my $undefined;
    return $undefined            if !$upload;
    return $upload->asset->slurp if $upload->can('asset') && $upload->asset;
    return $upload->slurp        if $upload->can('slurp');

    croak 'unsupported upload object';
}

sub _client_media_type ($input) {
    my $undefined;
    return $input->{media_type} if defined $input->{media_type};

    my $upload = $input->{upload};
    return $undefined if !$upload;
    return $upload->headers->content_type
      if $upload->can('headers') && $upload->headers;

    return $undefined;
}

sub _original_filename ($input) {
    return $input->{original_filename}
      if _has_text( $input->{original_filename} );

    my $upload = $input->{upload};
    return $upload->filename if $upload && $upload->can('filename');

    my $undefined;
    return $undefined;
}

sub _has_text ($value) {
    return defined $value && length $value ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Service::Attachment::UploadPipeline - Validate, store, scan and link an uploaded attachment.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $pipeline = GPForum::Service::Attachment::UploadPipeline->new(
        antivirus => $antivirus,    # or undef when scanning is off
        storage   => GPForum::Service::Attachment::FilesystemStorage->new,
        store     => $attachment_store,
    );

    my $result = $pipeline->upload_and_link(
        {
            actor_user_id => $user_id,
            target_id     => $post_id,
            target_type   => 'post',
            upload        => $controller->req->upload('attachment'),
        }
    );
    return $result->{errors} if !$result->{ok};

=head1 DESCRIPTION

One upload, start to finish. The bytes come from C<content> or from an
upload object; their media type is sniffed and the upload is checked by
L<GPForum::Service::Attachment::Validator>. A valid upload gets an intent from
L<GPForum::Service::Attachment::IntentBuilder>, its bytes are written to the
storage backend, and L<GPForum::Service::Attachment::Store> records the
intent and marks it uploaded. When a target is named, the attachment is
linked to it.

The scan verdict is the one the upload can reach by itself (ADR 0108). With
no C<antivirus> (scanning off) the media type check that already passed is
the whole verdict, recorded as a clean scan by C<format-check>. A scanner
that answers immediately, such as the system's clamd, scans the bytes during
the request. A slow scanner, or one that returns an error, leaves the upload
C<pending>: the attachment worker scans it later, and nothing pending is
served.

=head1 SUBROUTINES/METHODS

=head2 upload_and_link

Takes a hash reference with the bytes in C<content> or an C<upload> object
(one with C<asset> or C<slurp>, such as a L<Mojo::Upload>), and
C<actor_user_id>; optionally C<media_type> and C<original_filename>, which
otherwise come from the upload object, and C<target_type> and C<target_id>
to link the attachment.

Returns C<< { ok => 0, errors => { attachment => 'attachment is required' } } >>
when there are no bytes, and the validator's C<< { ok => 0, errors => ... } >>
when the upload is invalid. Otherwise returns C<< ok => 1 >> with
C<attachment> (the intent plus the validated C<media_type>, the C<state> and
the C<scan_status>, C<pending> unless a scan was recorded), C<created> (what
the store's C<create_intent> returned) and C<link> (the new link, or undef
when no target was given).

=head1 DIAGNOSTICS

Validation failures are returned. Croaks C<unsupported upload object> when
C<upload> has neither C<asset> nor C<slurp>. Errors from the storage
backend and the store propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None here: the bootstrap passes C<antivirus> from the configuration, or undef
when the operator turned scanning off.

=head1 DEPENDENCIES

L<GPForum::Service::Attachment::IntentBuilder>,
L<GPForum::Service::Attachment::Store>,
L<GPForum::Service::Attachment::Validator>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
