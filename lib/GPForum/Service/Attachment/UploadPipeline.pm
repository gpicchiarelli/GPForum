package GPForum::Service::Attachment::UploadPipeline;

use strict;
use warnings;

use Carp        qw(croak);
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base;

use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::Store;
use GPForum::Service::Attachment::Validator;

our $VERSION = '0.001';

has intent_builder => sub {
    return GPForum::Service::Attachment::IntentBuilder->new;
};
has storage   => undef;
has store     => sub { return GPForum::Service::Attachment::Store->new; };
has validator => sub { return GPForum::Service::Attachment::Validator->new; };

sub upload_and_link {
    my ( $self, $input ) = @_;

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
    my $scanned  = $self->store->record_scan(
        {
            actor_id      => 'local-sniffer',
            attachment_id => $intent->{attachment_id},
            scan_status   => 'clean',
        }
    );
    my $link = $self->_link_target( $input, $intent->{attachment_id} );

    return {
        ok         => 1,
        attachment => {
            %{$intent},
            media_type  => $validated->{values}{media_type},
            state       => $scanned->{state} || $uploaded->{state},
            scan_status => $scanned->{scan_status},
        },
        created => $created,
        link    => $link,
    };
}

sub cleanup_orphans {
    my ( $self, $input ) = @_;

    my $cleanup = $self->store->cleanup_orphans($input);
    for my $attachment ( @{ $cleanup->{deleted} } ) {
        $self->storage->delete_object( $attachment->{object_key} )
          if defined $attachment->{object_key};
    }

    return $cleanup;
}

sub _link_target {
    my ( $self, $input, $attachment_id ) = @_;

    return if !_has_text( $input->{target_type} );
    return if !_has_text( $input->{target_id} );

    return $self->store->link_attachment(
        {
            attachment_id => $attachment_id,
            target_id     => $input->{target_id},
            target_type   => $input->{target_type},
        }
    );
}

sub _upload_content {
    my ($input) = @_;

    return $input->{content} if defined $input->{content};

    my $upload = $input->{upload};
    return                       if !$upload;
    return $upload->asset->slurp if $upload->can('asset') && $upload->asset;
    return $upload->slurp        if $upload->can('slurp');

    croak 'unsupported upload object';
}

sub _client_media_type {
    my ($input) = @_;

    return $input->{media_type} if defined $input->{media_type};

    my $upload = $input->{upload};
    return if !$upload;
    return $upload->headers->content_type
      if $upload->can('headers') && $upload->headers;

    return;
}

sub _original_filename {
    my ($input) = @_;

    return $input->{original_filename}
      if _has_text( $input->{original_filename} );

    my $upload = $input->{upload};
    return $upload->filename if $upload && $upload->can('filename');

    return;
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value ? 1 : 0;
}

1;
