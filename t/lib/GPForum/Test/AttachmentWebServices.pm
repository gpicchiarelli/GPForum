package GPForum::Test::AttachmentWebServices;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has upload_calls => sub { return []; };

sub check {
    return { ok => 1 };
}

sub find_visible_post {
    my ( $self, $post_id ) = @_;

    return if $post_id ne 'post-1';

    return {
        post_id          => 'post-1',
        thread_id        => 'thread-1',
        author_user_id   => 'user-1',
        visibility       => 'public',
        moderation_state => 'visible',
        deleted_at       => undef,
        hidden_at        => undef,
    };
}

sub upload_and_link {
    my ( $self, $input ) = @_;

    push @{ $self->upload_calls }, $input;

    return { ok => 0, errors => { attachment => 'attachment is required' } }
      if !$input->{upload};

    return {
        ok         => 1,
        attachment => {
            attachment_id     => 'attachment-1',
            byte_size         => 8,
            media_type        => 'image/png',
            original_filename => 'photo.png',
            scan_status       => 'clean',
            state             => 'available',
        },
        link => {
            attachment_id      => 'attachment-1',
            attachment_link_id => 'link-1',
            target_id          => 'post-1',
            target_type        => 'post',
        },
    };
}

sub download {
    my ( $self, $input ) = @_;

    return { ok => 0, error => 'not_found' }
      if $input->{attachment_id} eq 'missing';
    return { ok => 0, error => 'forbidden' }
      if $input->{attachment_id} eq 'hidden';

    return {
        ok                => 1,
        attachment_id     => $input->{attachment_id},
        byte_size         => 8,
        content           => "\x89PNG\x0d\x0a\x1a\x0a",
        media_type        => 'image/png',
        object_key        => 'attachments/user-1/attachment-1',
        original_filename => 'photo.png',
    };
}

1;
