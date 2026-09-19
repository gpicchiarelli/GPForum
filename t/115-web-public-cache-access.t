package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Test::PublicCacheRequest;
use GPForum::Web::PublicCacheAccess;
use Mojo::Date;
use Test::More;

our $VERSION = '0.001';

const my $EPOCH => 1_716_464_000;
const my $ETAG  => 'W/"abc123"';

my $access = GPForum::Web::PublicCacheAccess->new;
my $get    = GPForum::Test::PublicCacheRequest->new;
ok( $access->is_cacheable($get), 'is_cacheable accepts anonymous GET' );

my $head = GPForum::Test::PublicCacheRequest->new( method => 'HEAD' );
ok( $access->is_cacheable($head), 'is_cacheable accepts anonymous HEAD' );

my $post = GPForum::Test::PublicCacheRequest->new( method => 'POST' );
ok( !$access->is_cacheable($post), 'is_cacheable rejects POST' );

my $member =
  GPForum::Test::PublicCacheRequest->new( session_user_id => 'user-1', );
ok( !$access->is_cacheable($member),
    'is_cacheable rejects an authenticated GET' );

ok(
    $access->etag_matches( $ETAG, $ETAG ),
    'etag_matches accepts the exact ETag'
);
ok( $access->etag_matches( q{*}, $ETAG ),
    'etag_matches accepts a wildcard If-None-Match' );
ok( $access->etag_matches( join( q{, }, $ETAG, 'W/"other"' ), $ETAG ),
    'etag_matches accepts a listed ETag' );
ok(
    !$access->etag_matches( 'W/"other"', $ETAG ),
    'etag_matches rejects a different ETag'
);
ok(
    !$access->etag_matches( undef, $ETAG ),
    'etag_matches rejects a missing candidate'
);

my $date = Mojo::Date->new($EPOCH)->to_string;
ok(
    $access->modified_since_matches( $date, $EPOCH ),
    'modified_since_matches accepts an equal Last-Modified'
);
ok(
    !$access->modified_since_matches( $date, $EPOCH + 1 ),
    'modified_since_matches rejects a newer cache entry'
);
ok(
    !$access->modified_since_matches( 'not-a-date', $EPOCH ),
    'modified_since_matches rejects an unparsable date'
);

my $fresh = GPForum::Test::PublicCacheRequest->new( if_none_match => $ETAG );
ok(
    $access->client_has_fresh_copy(
        $fresh, { etag => $ETAG, last_modified_epoch => $EPOCH }
    ),
    'client_has_fresh_copy follows If-None-Match'
);

my $stale = GPForum::Test::PublicCacheRequest->new;
ok(
    !$access->client_has_fresh_copy(
        $stale, { etag => $ETAG, last_modified_epoch => $EPOCH }
    ),
    'client_has_fresh_copy is false without conditional headers'
);

is( $access->revalidated_state('hit'),
    'revalidated', 'revalidated_state labels a hit' );
is( $access->revalidated_state('miss'),
    'miss-revalidated', 'revalidated_state labels a stored miss' );

done_testing();

1;
