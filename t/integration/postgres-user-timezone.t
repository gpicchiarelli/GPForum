# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Identity::PreferenceStore;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $TOO_LONG => 65;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the user time zone test';
}

# 9.3 on PostgreSQL: migration 044's column, NULL for the forum default, and
# the store's round trip on a real user row.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );

my $schema = GPForum::Test::PostgresHarness::connect_schema();
my $dbh    = $schema->storage->dbh;
my ($user_id) =
  $dbh->selectrow_array('SELECT id FROM users ORDER BY username LIMIT 1');
ok( $user_id, 'the seed has a member' );
is( _stored(), undef, 'who follows the forum default until they choose' );

my $store =
  GPForum::Service::Identity::PreferenceStore->new( schema => $schema );
ok(
    $store->update_preferred_timezone(
        { preferred_timezone => 'Europe/Rome', user_id => $user_id }
    )->{ok},
    'a member chooses a zone'
);
is( _stored(), 'Europe/Rome', 'and PostgreSQL keeps it' );
ok(
    $store->update_preferred_timezone(
        { preferred_timezone => q{}, user_id => $user_id }
    )->{ok},
    'and can go back to the default'
);
is( _stored(), undef, 'stored as NULL' );

my $refused = eval {
    $dbh->do( 'UPDATE users SET preferred_timezone = ? WHERE id = ?',
        undef, 'x' x $TOO_LONG, $user_id );
    1;
};
ok( !$refused, 'the column refuses a value no zone name has' );
like(
    $EVAL_ERROR,
    qr/users_preferred_timezone_length_check/msx,
    'by its check constraint'
);

$dbh->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _stored {
    return
      scalar $dbh->selectrow_array(
        'SELECT preferred_timezone FROM users WHERE id = ?',
        undef, $user_id );
}

1;
