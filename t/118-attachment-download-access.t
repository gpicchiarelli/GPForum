package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::Attachment::DownloadAccess;
use GPForum::Service::Attachment::Record;
use Test::More;

our $VERSION = '0.001';

const my $BYTE_SIZE => 12;

my $records = GPForum::Service::Attachment::Record->new;
my $row     = {
    attachment_id     => 'att-1',
    byte_size         => $BYTE_SIZE,
    media_type        => 'image/png',
    object_key        => 'attachments/user-1/att-1',
    original_filename => 'photo.png',
    owner_user_id     => 'user-1',
    scan_status       => 'clean',
    state             => 'available',
};
is( $records->column( $row, 'state' ),
    'available', 'record reads hash columns' );
is_deeply(
    $records->view($row),
    {
        attachment_id     => 'att-1',
        byte_size         => $BYTE_SIZE,
        media_type        => 'image/png',
        original_filename => 'photo.png',
    },
    'record view keeps public attachment fields'
);
ok( $records->has_text('user-1'), 'record treats non-empty strings as text' );
ok( !$records->has_text(q{}),     'record rejects empty strings' );

my $access    = GPForum::Service::Attachment::DownloadAccess->new;
my $available = { %{$row}, deleted_at => undef };
ok( $access->downloadable($available),
    'downloadable accepts a clean available attachment' );
ok(
    !$access->downloadable( { %{$available}, state => 'uploaded' } ),
    'downloadable rejects an attachment that is not available'
);
ok( !$access->downloadable( { %{$available}, scan_status => 'infected' } ),
    'downloadable rejects a quarantined scan' );
ok(
    !$access->downloadable(
        { %{$available}, deleted_at => '2026-09-19T00:00:00Z' }
    ),
    'downloadable rejects a deleted attachment'
);
is( $access->unavailable(undef)->{error},
    'not_found', 'unavailable maps a missing attachment to not_found' );

my $public = {
    author_user_id   => 'user-2',
    moderation_state => 'visible',
    visibility       => 'public',
};
ok(
    $access->visibility_allows( $public, $available, undef ),
    'visibility allows anonymous public downloads'
);

my $members = { %{$public}, visibility => 'members' };
ok(
    !$access->visibility_allows( $members, $available, undef ),
    'visibility rejects anonymous member downloads'
);
ok( $access->visibility_allows( $members, $available, 'user-9' ),
    'visibility allows signed-in member downloads' );

my $private = { %{$public}, visibility => 'private' };
ok( $access->visibility_allows( $private, $available, 'user-2' ),
    'visibility allows the private-thread author' );
ok(
    $access->visibility_allows( $private, $available, 'user-1' ),
    'visibility allows the attachment owner on a private target'
);
ok(
    !$access->visibility_allows( $private, $available, 'user-9' ),
    'visibility rejects an unrelated private viewer'
);

ok(
    $access->target_visible(
        {
            deleted_at       => undef,
            hidden_at        => undef,
            moderation_state => 'locked',
        },
        'thread'
    ),
    'target_visible accepts a locked thread'
);
ok(
    !$access->target_visible(
        {
            deleted_at       => undef,
            hidden_at        => '2026-09-19T00:00:00Z',
            moderation_state => 'visible',
        },
        'post'
    ),
    'target_visible rejects a hidden post'
);

ok(
    $access->link_allows(
        {
            attachment     => $available,
            link           => { target_type => 'profile' },
            target         => undef,
            viewer_user_id => 'user-1',
        }
    ),
    'link_allows grants profile downloads to the owner'
);
ok(
    !$access->link_allows(
        {
            attachment     => $available,
            link           => { target_type => 'profile' },
            target         => undef,
            viewer_user_id => 'user-9',
        }
    ),
    'link_allows rejects profile downloads for other viewers'
);

my $payload = $access->payload($available);
ok( $payload->{ok}, 'payload marks an authorized download' );
is( $payload->{object_key},
    'attachments/user-1/att-1',
    'payload includes storage fields from the attachment row' );

my $owner_download = $access->authorized(
    {
        attachment     => $available,
        linked         => [],
        viewer_user_id => 'user-1',
    }
);
ok( $owner_download->{ok},
    'authorized grants an unlinked download to the owner' );

my $stranger_download = $access->authorized(
    {
        attachment     => $available,
        linked         => [],
        viewer_user_id => 'user-9',
    }
);
is( $stranger_download->{error},
    'forbidden', 'authorized rejects an unlinked download for other viewers' );

my $public_download = $access->authorized(
    {
        attachment => $available,
        linked     => [
            {
                link   => { target_type => 'post' },
                target => $public,
            }
        ],
        viewer_user_id => undef,
    }
);
ok( $public_download->{ok},
    'authorized grants an anonymous public linked download' );

my $profile_denied = $access->authorized(
    {
        attachment => $available,
        linked     => [
            {
                link   => { target_type => 'profile' },
                target => undef,
            }
        ],
        viewer_user_id => 'user-9',
    }
);
is( $profile_denied->{error},
    'forbidden', 'authorized rejects a profile link for other viewers' );

done_testing();

1;
