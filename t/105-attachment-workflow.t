# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Attachment::Workflow;
use GPForum::Test::AttachmentWebServices;
use GPForum::Test::BrokenAttachmentServices;
use GPForum::Test::CommandIdempotency;
use Test::More;

our $VERSION = '0.001';

my $services = GPForum::Test::AttachmentWebServices->new;
my $workflow = GPForum::Service::Attachment::Workflow->new(
    delivery    => $services,
    pipeline    => $services,
    post_reader => $services,
    store       => $services,
);

my $missing_command = $workflow->upload_for_post(
    {
        actor_user_id => 'user-1',
        post_id       => 'post-1',
        upload        => { filename => 'photo.png' },
    }
);
is( $missing_command->{status},
    'invalid', 'upload_for_post rejects a missing command_id' );
is(
    $missing_command->{errors}{command_id},
    'command_id is required',
    'upload_for_post names the missing command_id'
);

my $uploaded = $workflow->upload_for_post(
    {
        actor_user_id => 'user-1',
        command_id    => 'upload-1',
        post_id       => 'post-1',
        upload        => { filename => 'photo.png' },
    }
);
ok( $uploaded->{ok}, 'upload_for_post succeeds for the post author' );
is( $uploaded->{stored}{attachment}{attachment_id},
    'attachment-1', 'upload_for_post stores the linked attachment' );
is( $uploaded->{stored}{post}{thread_id},
    'thread-1', 'upload_for_post keeps the post for HTTP redirects' );

my $invalid = $workflow->upload_for_post(
    {
        actor_user_id => 'user-1',
        command_id    => 'upload-invalid-1',
        post_id       => 'post-1',
        upload        => undef,
    }
);
is( $invalid->{status}, 'invalid',
    'upload_for_post maps pipeline errors to invalid' );
is(
    $invalid->{errors}{attachment},
    'attachment is required',
    'upload_for_post keeps pipeline field errors'
);

my $missing_post = $workflow->upload_for_post(
    {
        actor_user_id => 'user-1',
        command_id    => 'upload-missing-post-1',
        post_id       => 'missing',
        upload        => { filename => 'photo.png' },
    }
);
is( $missing_post->{status},
    'not_found', 'upload_for_post maps a missing post to not_found' );

my $forbidden = $workflow->upload_for_post(
    {
        actor_user_id => 'user-2',
        command_id    => 'upload-forbidden-1',
        post_id       => 'post-1',
        upload        => { filename => 'photo.png' },
    }
);
is( $forbidden->{status},
    'forbidden', 'upload_for_post rejects a non-author upload' );
is(
    $forbidden->{error},
    'post author required',
    'upload_for_post names the author requirement'
);

my $deleted = $workflow->delete_for_post(
    {
        actor_user_id => 'user-1',
        attachment_id => 'attachment-1',
        command_id    => 'delete-1',
        post_id       => 'post-1',
    }
);
ok( $deleted->{ok}, 'delete_for_post succeeds for the post author' );
is( $deleted->{stored}{attachment}{attachment_id},
    'attachment-1', 'delete_for_post returns the deleted attachment' );
is( $deleted->{stored}{post}{thread_id},
    'thread-1', 'delete_for_post keeps the post for HTTP redirects' );

my $missing_attachment = $workflow->delete_for_post(
    {
        actor_user_id => 'user-1',
        attachment_id => 'missing',
        command_id    => 'delete-missing-1',
        post_id       => 'post-1',
    }
);
is( $missing_attachment->{status},
    'not_found', 'delete_for_post maps a missing link to not_found' );

my $missing_delete_post = $workflow->delete_for_post(
    {
        actor_user_id => 'user-1',
        attachment_id => 'attachment-1',
        command_id    => 'delete-missing-post-1',
        post_id       => 'missing',
    }
);
is( $missing_delete_post->{status},
    'not_found', 'delete_for_post maps a missing post to not_found' );

my $forbidden_delete = $workflow->delete_for_post(
    {
        actor_user_id => 'user-2',
        attachment_id => 'attachment-1',
        command_id    => 'delete-forbidden-1',
        post_id       => 'post-1',
    }
);
is( $forbidden_delete->{status},
    'forbidden', 'delete_for_post rejects a non-author delete' );

my $downloaded = $workflow->download(
    {
        attachment_id  => 'attachment-1',
        viewer_user_id => 'user-1',
    }
);
ok( $downloaded->{ok}, 'download succeeds for a visible attachment' );
is( $downloaded->{stored}{media_type},
    'image/png', 'download returns delivery metadata' );

my $missing_file = $workflow->download(
    {
        attachment_id  => 'missing',
        viewer_user_id => 'user-1',
    }
);
is( $missing_file->{status},
    'not_found', 'download maps a missing object to not_found' );

my $hidden = $workflow->download(
    {
        attachment_id  => 'hidden',
        viewer_user_id => 'user-1',
    }
);
is( $hidden->{status}, 'forbidden',
    'download maps an unavailable object to forbidden' );
is( $hidden->{error}, 'forbidden', 'download keeps the delivery denial error' );

my $broken = GPForum::Service::Attachment::Workflow->new(
    delivery    => GPForum::Test::BrokenAttachmentServices->new,
    pipeline    => GPForum::Test::BrokenAttachmentServices->new,
    post_reader => $services,
    store       => GPForum::Test::BrokenAttachmentServices->new,
);
my $failed_upload = $broken->upload_for_post(
    {
        actor_user_id => 'user-1',
        command_id    => 'upload-failed-1',
        post_id       => 'post-1',
        upload        => { filename => 'photo.png' },
    }
);
is( $failed_upload->{status},
    'failed', 'upload_for_post maps pipeline exceptions to failed' );

my $failed_download = $broken->download(
    {
        attachment_id  => 'attachment-1',
        viewer_user_id => 'user-1',
    }
);
is( $failed_download->{status},
    'failed', 'download maps delivery exceptions to failed' );

my $failed_delete = $broken->delete_for_post(
    {
        actor_user_id => 'user-1',
        attachment_id => 'attachment-1',
        command_id    => 'delete-failed-1',
        post_id       => 'post-1',
    }
);
is( $failed_delete->{status},
    'failed', 'delete_for_post maps store exceptions to failed' );

my $idempotency = GPForum::Test::CommandIdempotency->new;
my $commanded   = GPForum::Service::Attachment::Workflow->new(
    command_idempotency => $idempotency,
    delivery            => $services,
    pipeline            => $services,
    post_reader         => $services,
    store               => $services,
);
_replay_attachment(
    {
        commanded    => $commanded,
        command_type => 'attachment.upload',
        idempotency  => $idempotency,
        input        => {
            actor_user_id => 'user-1',
            command_id    => 'upload-replay-1',
            post_id       => 'post-1',
            upload        => { filename => 'photo.png' },
        },
        method  => 'upload_for_post',
        request => {
            actor_user_id => 'user-1',
            post_id       => 'post-1',
        },
        services => $services,
    }
);
_replay_attachment(
    {
        commanded    => $commanded,
        command_type => 'attachment.delete',
        idempotency  => $idempotency,
        input        => {
            actor_user_id => 'user-1',
            attachment_id => 'attachment-1',
            command_id    => 'delete-replay-1',
            post_id       => 'post-1',
        },
        method  => 'delete_for_post',
        request => {
            actor_user_id => 'user-1',
            attachment_id => 'attachment-1',
            post_id       => 'post-1',
        },
        services => $services,
    }
);

done_testing();

sub _store_writes {
    my ( $store, $method ) = @_;

    if ( $method eq 'delete_for_post' ) {
        return scalar @{ $store->delete_calls };
    }

    return scalar @{ $store->upload_calls };
}

sub _replay_attachment {
    my ($job) = @_;

    my $method       = $job->{method};
    my $write_issued = $job->{commanded}->$method( $job->{input} );
    ok( $write_issued->{ok}, "$method records a command" );
    is( $job->{idempotency}->last_input->{command_type},
        $job->{command_type}, "$method uses $job->{command_type}" );
    is_deeply( $job->{idempotency}->last_input->{request},
        $job->{request}, "$method command log omits uploaded bytes" );
    my $write_count    = _store_writes( $job->{services}, $method );
    my $write_replayed = GPForum::Service::Attachment::Workflow->new(
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            replay_response => $write_issued,
        ),
        delivery    => $job->{services},
        pipeline    => $job->{services},
        post_reader => $job->{services},
        store       => $job->{services},
    )->$method( $job->{input} );
    is_deeply( $write_replayed, $write_issued,
        "$method replays the recorded result" );
    is( _store_writes( $job->{services}, $method ),
        $write_count, "$method replay does not persist twice" );
    my $write_conflict = GPForum::Service::Attachment::Workflow->new(
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            conflict => 1,
        ),
        delivery    => $job->{services},
        pipeline    => $job->{services},
        post_reader => $job->{services},
        store       => $job->{services},
    )->$method( $job->{input} );
    is( $write_conflict->{status},
        'conflict', "$method rejects a reused command_id for another request" );

    return;
}

1;
