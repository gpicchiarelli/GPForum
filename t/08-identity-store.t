package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::Id;
use GPForum::Test::Schema;
use GPForum::Service::Identity::Store;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 13;

plan tests => $EXPECTED_TESTS;

my $schema = GPForum::Test::Schema->new;
my $store  = GPForum::Service::Identity::Store->new(
    schema     => $schema,
    id_service => GPForum::Test::Id->new,
);

my $registration = {
    user => {
        id               => 'user-1',
        username         => 'giacomo',
        display_name     => 'Giacomo Picchiarelli',
        email_normalized => 'giacomo@example.test',
        status           => 'pending',
        trust_level      => 0,
    },
    credential => {
        type        => 'password',
        secret_hash => 'argon2id-hash',
    },
};

my $created = $store->create_registration($registration);

ok( $created->{ok}, 'registration is persisted' );
is( scalar @{ $schema->created_for('User') }, 1, 'user row is created' );
is( scalar @{ $schema->created_for('Credential') },
    1, 'credential row is created' );
is( scalar @{ $schema->created_for('EventLog') }, 1, 'event row is created' );
is( scalar @{ $schema->created_for('AuditLog') }, 1, 'audit row is created' );
is( $schema->created_for('Credential')->[0]{user_id},
    'user-1', 'credential is linked to user' );
is( $schema->created_for('EventLog')->[0]{event_type},
    'user.registered', 'registration event is recorded' );
is( $schema->created_for('AuditLog')->[0]{action},
    'user.registered', 'registration audit is recorded' );
is( $schema->transaction_count, 1, 'registration uses one transaction' );

my $duplicate_schema = GPForum::Test::Schema->new(
    existing_usernames => { giacomo                => 1 },
    existing_emails    => { 'giacomo@example.test' => 1 },
);
my $duplicate_store = GPForum::Service::Identity::Store->new(
    schema     => $duplicate_schema,
    id_service => GPForum::Test::Id->new,
);

my $duplicate = $duplicate_store->create_registration($registration);

ok( !$duplicate->{ok}, 'duplicate registration is rejected' );
is(
    $duplicate->{errors}{username},
    'username is already registered',
    'duplicate username is reported'
);
is(
    $duplicate->{errors}{email},
    'email is already registered',
    'duplicate email is reported'
);
is( $duplicate_schema->transaction_count,
    0, 'duplicate registration does not open transaction' );

1;
