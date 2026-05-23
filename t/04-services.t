package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 3;

plan tests => $EXPECTED_TESTS;

my $clock             = GPForum::Service::Clock->new;
my $id                = GPForum::Service::Id->new;
my $hex3              = qr/[[:xdigit:]]{3}/msx;
my $hex4              = qr/[[:xdigit:]]{4}/msx;
my $hex8              = qr/[[:xdigit:]]{8}/msx;
my $hex12             = qr/[[:xdigit:]]{12}/msx;
my $uuid_version_four = qr/\A $hex8 - $hex4 - 4 $hex3 - $hex4 - $hex12 \z/msx;

like(
    $clock->now_epoch,
    qr/\A [[:digit:]]+ \z/msx,
    'clock returns epoch seconds'
);
like(
    $clock->now_iso8601,
    qr/\A [[:digit:]]{4} - [[:digit:]]{2} - [[:digit:]]{2} T /msx,
    'clock returns ISO-8601 UTC timestamp',
);
like( $id->uuid, $uuid_version_four, 'id service returns a version-four UUID' );

1;
