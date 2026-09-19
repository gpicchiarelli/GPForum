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
