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

sub cleanup_orphans ( $self, $input ) {
    my $cleanup = $self->store->cleanup_orphans($input);
    for my $attachment ( @{ $cleanup->{deleted} } ) {
        $self->storage->delete_object( $attachment->{object_key} )
          if defined $attachment->{object_key};
    }

    return $cleanup;
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
