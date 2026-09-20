package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Identity::RegistrationStore;
use GPForum::Test::RegistrationStoreServices;
use GPForum::Test::Schema;
use Test::More;

our $VERSION = '0.001';

my $services = GPForum::Test::RegistrationStoreServices->new;
my $schema   = GPForum::Test::Schema->new;
my $store    = GPForum::Service::Identity::RegistrationStore->new(
    audit            => $services,
    credential_store => $services,
    id_service       => $services,
    schema           => $schema,
);

my $created = $store->create_registration( _registration() );
ok( $created->{ok}, 'create_registration succeeds for a new account' );
is( $schema->created_for('User')->[0]{username},
    'giacomo', 'create_registration persists the user row' );
is( $services->credentials->[0]{user_id},
    'user-1', 'create_registration creates the password credential' );
is( $services->registrations->[0]{correlation_id},
    'generated-1', 'create_registration audits the registration' );
is( $schema->users->[0]{password_hash},
    'argon2id-hash', 'create_registration copies the credential hash' );
is( $schema->transaction_count, 1, 'create_registration uses one transaction' );

my $duplicate_schema = GPForum::Test::Schema->new(
    existing_emails    => { 'giacomo@example.test' => 1 },
    existing_usernames => { giacomo                => 1 },
);
my $duplicate_store = GPForum::Service::Identity::RegistrationStore->new(
    audit            => $services,
    credential_store => $services,
    id_service       => $services,
    schema           => $duplicate_schema,
);
my $duplicate = $duplicate_store->create_registration( _registration() );
ok( !$duplicate->{ok}, 'create_registration rejects a duplicate account' );
is(
    $duplicate->{errors}{username},
    'username is already registered',
    'create_registration reports a duplicate username'
);
is(
    $duplicate->{errors}{email},
    'email is already registered',
    'create_registration reports a duplicate email'
);
is( $duplicate_schema->transaction_count,
    0, 'create_registration does not open a transaction for duplicates' );

my $race_services = GPForum::Test::RegistrationStoreServices->new;
my $race_schema   = GPForum::Test::Schema->new(
    find_misses => 2,
    users       => [
        {
            email_normalized => 'giacomo@example.test',
            id               => 'user-other',
            username         => 'giacomo',
        },
    ],
);
my $race_store = GPForum::Service::Identity::RegistrationStore->new(
    audit            => $race_services,
    credential_store => $race_services,
    id_service       => $race_services,
    schema           => $race_schema,
);
my $raced = $race_store->create_registration( _registration() );
ok( !$raced->{ok}, 'registration unique race is rejected' );
is(
    $raced->{errors}{username},
    'username is already registered',
    'registration unique race reports a duplicate username'
);
is(
    $raced->{errors}{email},
    'email is already registered',
    'registration unique race reports a duplicate email'
);
is( scalar @{ $race_schema->users },
    1, 'registration unique race does not insert another user' );
is( scalar @{ $race_services->credentials },
    0, 'registration unique race does not insert another credential' );
is( $race_schema->transaction_count,
    1, 'registration unique race opens a transaction' );

my $id_services = GPForum::Test::RegistrationStoreServices->new;
my $id_schema   = GPForum::Test::Schema->new(
    users => [
        {
            email_normalized => 'other@example.test',
            id               => 'user-1',
            username         => 'other-user',
        }
    ]
);
my $id_store = GPForum::Service::Identity::RegistrationStore->new(
    audit            => $id_services,
    credential_store => $id_services,
    id_service       => $id_services,
    schema           => $id_schema,
);
my $id_result = $id_store->create_registration( _registration() );
ok( $id_result->{ok}, 'unique user id collision remints and persists' );
is( $id_schema->created_for('User')->[0]{id},
    'generated-1', 'unique user id collision remints the id' );
is( $id_services->credentials->[0]{user_id},
    'generated-1', 'unique user id collision does not return another user' );
is( $id_schema->created_for('User')->[0]{username},
    'giacomo', 'unique user id collision keeps the minted username' );

my $leftover_services = GPForum::Test::RegistrationStoreServices->new;
my $leftover_schema   = GPForum::Test::Schema->new(
    find_misses => 2,
    users       => [
        {
            email_normalized => 'giacomo@example.test',
            id               => 'user-1',
            username         => 'giacomo',
        }
    ]
);
my $leftover_store = GPForum::Service::Identity::RegistrationStore->new(
    audit            => $leftover_services,
    credential_store => $leftover_services,
    id_service       => $leftover_services,
    schema           => $leftover_schema,
);
my $leftover = $leftover_store->create_registration( _registration() );
ok( $leftover->{ok}, 'leftover user id race reuses and persists' );
is( $leftover_schema->users->[0]{id},
    'user-1', 'leftover user id race keeps this account' );
is( scalar @{ $leftover_schema->users },
    1, 'leftover user id race does not insert a second user' );
is( $leftover_services->credentials->[0]{user_id},
    'user-1', 'leftover user id race inserts the missing credential' );

done_testing();

sub _registration {
    return {
        credential => {
            secret_hash => 'argon2id-hash',
            type        => 'password',
        },
        user => {
            email_normalized => 'giacomo@example.test',
            id               => 'user-1',
            username         => 'giacomo',
        },
    };
}

1;
