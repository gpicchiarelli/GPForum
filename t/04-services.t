# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;
use GPForum::Service::Password;
use GPForum::Service::SessionToken;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 17;
const my $ONE_MINUTE     => 60;

plan tests => $EXPECTED_TESTS;

my $clock     = GPForum::Service::Clock->new;
my $id        = GPForum::Infrastructure::Id->new;
my $passwords = GPForum::Service::Password->new;
my $sessions  = GPForum::Service::SessionToken->new;
my $hex3      = qr/[[:xdigit:]]{3}/msx;
my $hex4      = qr/[[:xdigit:]]{4}/msx;
my $hex8      = qr/[[:xdigit:]]{8}/msx;
my $hex12     = qr/[[:xdigit:]]{12}/msx;
my $variant   = qr/[89ab]/msx;
my $uuid_version_seven =
  qr/\A $hex8 - $hex4 - 7 $hex3 - $variant $hex3 - $hex12 \z/msx;

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
like(
    $clock->epoch_plus_iso8601($ONE_MINUTE),
    qr/\A [[:digit:]]{4} - [[:digit:]]{2} - [[:digit:]]{2} T /msx,
    'clock returns future ISO-8601 UTC timestamp',
);
like( $id->uuid, $uuid_version_seven, 'id service returns a UUIDv7' );

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

my $decoy = $passwords->decoy_hash;
like( $decoy, qr/\A [\$] argon2id [\$]/msx, 'the decoy is an Argon2id hash' );
is( GPForum::Service::Password->new->decoy_hash,
    $decoy, 'made once per process' );
ok( !$passwords->verify_password( 'correct horse battery staple', $decoy ),
    'and no password matches it' );

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
