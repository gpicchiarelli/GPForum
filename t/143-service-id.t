package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Id;
use GPForum::Test::Id;
use Test::More;

our $VERSION = '0.001';

ok( !exists $INC{'Crypt/URandom.pm'},
    'Crypt::URandom stays unloaded when Id compiles' );

ok( GPForum::Service::Id->new, 'Id constructs without generating a UUID' );
is( GPForum::Test::Id->new->uuid,
    'generated-1', 'injected Test::Id still supplies identifiers' );

ok( !exists $INC{'Crypt/URandom.pm'},
    'Crypt::URandom stays unloaded after construct and Test::Id' );

done_testing();

1;
