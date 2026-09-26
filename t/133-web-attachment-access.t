# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Web::AttachmentAccess;
use Test::More;

our $VERSION = '0.001';

const my $UPLOAD_LIMIT  => 20;
const my $UPLOAD_WINDOW => 60;

my $access = GPForum::Web::AttachmentAccess->new;

is_deeply(
    $access->upload_rate_input('user-1'),
    {
        action         => 'attachment.upload',
        actor_id       => 'user-1',
        limit          => $UPLOAD_LIMIT,
        scope          => 'forum_http',
        window_seconds => $UPLOAD_WINDOW,
    },
    'upload_rate_input uses the forum HTTP upload window'
);

is( $access->safe_filename(undef),
    'attachment', 'safe_filename defaults a missing name' );
is( $access->safe_filename(q{}),
    'attachment', 'safe_filename defaults an empty name' );
is( $access->safe_filename('photo"x.png'),
    'photo_x.png', 'safe_filename strips quotes' );
is( $access->safe_filename("note\r\n.txt"),
    'note__.txt', 'safe_filename strips line breaks' );
is(
    $access->content_disposition('photo"x.png'),
    'attachment; filename="photo_x.png"',
    'content_disposition quotes the sanitized filename'
);

ok(
    $access->is_failed( { status => 'failed' } ),
    'is_failed accepts a failed workflow'
);
ok(
    !$access->is_failed( { status => 'invalid' } ),
    'is_failed ignores mapped client errors'
);

is( $access->failure_status( { status => 'not_found' } ),
    'not_found', 'failure_status keeps not_found' );
is( $access->failure_status( { status => 'invalid' } ),
    'invalid', 'failure_status keeps invalid' );
is( $access->failure_status( { status => 'forbidden' } ),
    'forbidden', 'failure_status keeps forbidden' );
is( $access->failure_status( { status => 'conflict' } ),
    'invalid', 'failure_status maps conflict to invalid' );
ok( !defined $access->failure_status( { status => 'failed' } ),
    'failure_status ignores system failures' );
ok( !defined $access->failure_status( { status => 'ok' } ),
    'failure_status ignores success' );

is_deeply(
    $access->invalid_request(undef),
    {
        error  => 'The submitted attachment was invalid.',
        errors => {},
        title  => 'Invalid attachment',
    },
    'invalid_request defaults missing field errors'
);
is_deeply(
    $access->invalid_request( { post_id => 'post is required' } ),
    {
        error  => 'The submitted attachment was invalid.',
        errors => { post_id => 'post is required' },
        title  => 'Invalid attachment',
    },
    'invalid_request keeps explicit field errors'
);
is_deeply(
    $access->rate_limited_payload,
    {
        error => 'rate limit exceeded',
        title => 'Rate limited',
    },
    'rate_limited_payload keeps the attachment Guard extras'
);
is( $access->write_flash_key('uploaded'),
    'forum.attachment_uploaded',
    'write_flash_key maps upload to the flash key' );
is( $access->write_flash_key('deleted'),
    'forum.attachment_deleted',
    'write_flash_key maps delete to the flash key' );
is( $access->deleted_status, 'deleted', 'deleted_status exposes the status' );
ok(
    !defined $access->write_flash_key('unknown'),
    'write_flash_key ignores an unmapped status'
);

done_testing();

1;
