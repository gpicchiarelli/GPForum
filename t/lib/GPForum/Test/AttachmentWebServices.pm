# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::AttachmentWebServices;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

# A CR and an LF inside an object key: what header injection would look like
# arriving from a row. Built from chr() so the bytes are named rather than
# escaped inside a string.
# Parenthesised deliberately. Without the parens this is
# chr( 13 . chr( 10 . 'X-Injected: 1' ) ) -- named unary operators bind looser
# than concatenation -- which yielded a bare CR and dropped the header the test
# is supposed to be smuggling. perlcritic caught that; the test could not,
# because a lone CR fails the same whitelist.
const my $CARRIAGE_RETURN => 13;
const my $LINE_FEED       => 10;
const my $INJECTED_KEY => 'attachments/user-1/streamed'
  . chr($CARRIAGE_RETURN)
  . chr($LINE_FEED)
  . 'X-Injected: 1';

has delete_calls => sub { return []; };
has upload_calls => sub { return []; };
has check_calls  => sub { return []; };

# Actions named here are refused, so a controller can be shown to honour a
# limiter decision rather than merely to call one.
has denied_actions => sub { return {}; };

# When set, the 'streamed' attachment comes back as a path instead of bytes:
# that is the branch a real filesystem-backed delivery takes.
has streamed_path => undef;

# Returns an object key carrying a CRLF, to prove the hand-off refuses it.
has injected_key => 0;

sub check {
    my ( $self, $input ) = @_;

    push @{ $self->check_calls }, $input;
    return { ok => 0 } if $self->denied_actions->{ $input->{action} || q{} };

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

    if ( $input->{attachment_id} eq 'streamed' ) {
        return {
            ok            => 1,
            attachment_id => 'streamed',
            byte_size     => 8,
            media_type    => 'image/png',
            object_key    => $self->injected_key
            ? $INJECTED_KEY
            : 'attachments/user-1/streamed',
            object_path       => $self->streamed_path,
            original_filename => 'photo.png',
        };
    }

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

sub delete_linked {
    my ( $self, $input ) = @_;

    push @{ $self->delete_calls }, $input;

    if ( $input->{attachment_id} eq 'missing' ) {
        return { error => 'not_found', ok => 0 };
    }

    return {
        attachment => {
            attachment_id => $input->{attachment_id},
            state         => 'deleted',
        },
        ok => 1,
    };
}

1;
