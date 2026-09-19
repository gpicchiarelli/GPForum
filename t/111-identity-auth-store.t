package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Identity::AuthStore;
use GPForum::Test::AuthStoreServices;
use GPForum::Test::Schema;
use Test::More;

our $VERSION = '0.001';

my $services = GPForum::Test::AuthStoreServices->new(
    credentials => {
        'user-1' => { secret_hash => 'hashed:correct horse battery staple' },
        'user-pending' =>
          { secret_hash => 'hashed:correct horse battery staple' },
    },
);
my $schema = GPForum::Test::Schema->new(
    users => [
        {
            email_normalized => 'giacomo@example.test',
            id               => 'user-1',
            status           => 'active',
            username         => 'giacomo',
        },
        {
            email_normalized => 'gone@example.test',
            id               => 'user-deleted',
            status           => 'deleted',
            username         => 'gone',
        },
        {
            email_normalized => 'pending@example.test',
            id               => 'user-pending',
            status           => 'pending',
            username         => 'pending_user',
        },
    ],
);
my $store = GPForum::Service::Identity::AuthStore->new(
    credential_store => $services,
    password         => $services,
    schema           => $schema,
    session_store    => $services,
);

my $email_login = $store->authenticate_login(
    {
        identifier => 'GIACOMO@example.test',
        password   => 'correct horse battery staple',
    }
);
ok( $email_login->{ok}, 'authenticate_login succeeds for a known email' );
is( $email_login->{user_id},
    'user-1', 'authenticate_login returns the authenticated user id' );
is( $email_login->{session_id},
    'sess-1', 'authenticate_login opens a server session' );

my $username_login = $store->authenticate_login(
    {
        identifier => 'giacomo',
        password   => 'correct horse battery staple',
    }
);
ok( $username_login->{ok}, 'authenticate_login succeeds for a known username' );

my $unknown = $store->authenticate_login(
    {
        identifier => 'missing@example.test',
        password   => 'correct horse battery staple',
    }
);
ok( !$unknown->{ok}, 'authenticate_login rejects an unknown identifier' );
is( $unknown->{error}, 'invalid_credentials',
    'authenticate_login hides unknown identifiers' );

my $deleted = $store->authenticate_login(
    {
        identifier => 'gone',
        password   => 'correct horse battery staple',
    }
);
is( $deleted->{error},
    'invalid_credentials', 'authenticate_login hides deleted users' );

my $wrong = $store->authenticate_login(
    {
        identifier => 'giacomo',
        password   => 'wrong password value',
    }
);
is( $wrong->{error},
    'invalid_credentials', 'authenticate_login hides a wrong password' );

my $pending = $store->authenticate_login(
    {
        identifier => 'pending_user',
        password   => 'correct horse battery staple',
    }
);
is( $pending->{error},
    'unverified', 'authenticate_login rejects a pending account' );
ok( !$pending->{ok}, 'authenticate_login does not open a pending session' );

my $empty = $store->authenticate_login(
    {
        identifier => q{},
        password   => 'correct horse battery staple',
    }
);
is( $empty->{error},
    'invalid_credentials', 'authenticate_login rejects an empty identifier' );

is( scalar @{ $services->sessions },
    2, 'authenticate_login opens a session only after a matching password' );

done_testing();

1;
