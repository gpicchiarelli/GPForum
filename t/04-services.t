package main;

use strict;
use warnings;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Service::Clock;
use GPForum::Service::Id;
use GPForum::Service::Password;
use GPForum::Service::SessionToken;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 13;

plan tests => $EXPECTED_TESTS;

my $clock             = GPForum::Service::Clock->new;
my $id                = GPForum::Service::Id->new;
my $passwords         = GPForum::Service::Password->new;
my $sessions          = GPForum::Service::SessionToken->new;
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

my $password_hash = $passwords->hash_password('correct horse battery staple');

like(
    $password_hash,
    qr/\A \x{24} argon2id \x{24} /msx,
    'password hashing uses Argon2id'
);
ok(
    $passwords->verify_password(
        'correct horse battery staple',
        $password_hash
    ),
    'password verifies against its hash'
);
ok(
    !$passwords->verify_password(
        'incorrect horse battery staple',
        $password_hash
    ),
    'wrong password fails verification'
);
ok( !$passwords->verify_password( undef, $password_hash ),
    'undefined password fails verification' );
ok( !$passwords->verify_password( 'correct horse battery staple', undef ),
    'undefined password hash fails verification' );
ok(
    !$passwords->verify_password(
        'correct horse battery staple', 'not-argon2'
    ),
    'non-argon2 password hash fails verification'
);
throws_ok(
    sub {
        $passwords->hash_password('too-short');
    },
    qr/\A password [ ] must [ ] be [ ] at [ ] least/msx,
    'too-short password fails before hashing',
);

my $session_token = $sessions->issue_token;
my $session_hash  = $sessions->hash_token($session_token);

like(
    $session_token,
    qr/\A [[:xdigit:]]{64} \z/msx,
    'session token is random hex'
);
like(
    $session_hash,
    qr/\A [[:xdigit:]]{64} \z/msx,
    'session token hash is hex SHA-256'
);
isnt( $session_token, $session_hash,
    'raw session token is not stored as its hash' );

1;
