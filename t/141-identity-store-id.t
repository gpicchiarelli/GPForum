package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Digest::SHA qw(sha256_hex);
use GPForum::Service::Identity::Store;
use GPForum::Service::Password;
use GPForum::Service::SessionToken;
use GPForum::Test::Id;
use Test::More;

our $VERSION = '0.001';

ok( !exists $INC{'Crypt/URandom.pm'},
    'Crypt::URandom stays unloaded when identity compiles' );
ok(
    !exists $INC{'GPForum/Service/Id.pm'},
    'Id stays unloaded when identity compiles'
);

my $store =
  GPForum::Service::Identity::Store->new( id_service => GPForum::Test::Id->new,
  );
ok( $store, 'an injected identity store constructs without Id' );
is( $store->id_service->uuid,
    'generated-1', 'injected Test::Id supplies store identifiers' );

ok(
    !GPForum::Service::Password->new->verify_password(
        'correct horse battery staple', 'not-argon2'
    ),
    'password verify rejects a non-argon2 hash without URandom'
);

my $tokens = GPForum::Service::SessionToken->new;
is( $tokens->hash_token('raw-token'),
    sha256_hex('raw-token'),
    'session token hashing stays SHA-256 without URandom' );

ok( !exists $INC{'Crypt/URandom.pm'},
    'Crypt::URandom stays unloaded after injected identity use' );
ok(
    !exists $INC{'GPForum/Service/Id.pm'},
    'Id stays unloaded after injected identity use'
);

done_testing();

1;
