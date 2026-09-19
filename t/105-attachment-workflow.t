package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Attachment::Workflow;
use GPForum::Test::AttachmentWebServices;
use GPForum::Test::BrokenAttachmentServices;
use Test::More;

our $VERSION = '0.001';

my $services = GPForum::Test::AttachmentWebServices->new;
my $workflow = GPForum::Service::Attachment::Workflow->new(
    delivery    => $services,
    pipeline    => $services,
    post_reader => $services,
);

my $uploaded = $workflow->upload_for_post(
    {
        actor_user_id => 'user-1',
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
        post_id       => 'missing',
        upload        => { filename => 'photo.png' },
    }
);
is( $missing_post->{status},
    'not_found', 'upload_for_post maps a missing post to not_found' );

my $forbidden = $workflow->upload_for_post(
    {
        actor_user_id => 'user-2',
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
);
my $failed_upload = $broken->upload_for_post(
    {
        actor_user_id => 'user-1',
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

done_testing();

1;
