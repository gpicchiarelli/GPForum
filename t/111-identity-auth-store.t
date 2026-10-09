# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Identity::AuthStore;
use GPForum::Test::RecordingPassword;
use GPForum::Test::UnreachableSchema;
use Test::More;

our $VERSION = '0.001';

# A login with no identifier names no account to look up, so it is refused
# before the database is reached; it still verifies the password against the
# decoy, or its speed would set it apart from an unknown account. Every
# login that looks an account up runs on PostgreSQL, in
# t/integration/postgres-identity-stores.t.
my $password = GPForum::Test::RecordingPassword->new;

# The credential and session stores are never reached either; a call on
# one of these empty hashes would die.
my $store = GPForum::Service::Identity::AuthStore->new(
    credential_store => {},
    password         => $password,
    schema           => GPForum::Test::UnreachableSchema->new,
    session_store    => {},
);

my $empty = $store->authenticate_login(
    { identifier => q{}, password => 'correct horse battery staple' } );
is( $empty->{error},
    'invalid_credentials', 'authenticate_login rejects an empty identifier' );
is_deeply(
    $password->verified,
    [ $password->decoy_hash ],
    'after one verification, against the decoy'
);

done_testing();

1;
