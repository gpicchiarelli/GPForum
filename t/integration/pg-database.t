# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# The harness the fake-ORM tests move onto: a clone per test, of a template
# built once.
my $bare = GPForum::Test::PgDatabase->fresh;
is( _count( $bare, 'schema_versions' ) > 0, 1, 'a clone is migrated' );
is( _count( $bare, 'users' ),               0, 'and empty without the seed' );

my $seeded = GPForum::Test::PgDatabase->fresh( seed => 1 );
cmp_ok( _count( $seeded, 'users' ), q{>}, 0, 'the seeded clone has users' );

my $other = GPForum::Test::PgDatabase->fresh( seed => 1 );
$other->dbh->do('DELETE FROM user_feed_items');
$other->dbh->do('DELETE FROM notification_inbox');
is( _count( $other, 'user_feed_items' ), 0, 'a clone changes' );
isnt( $other->name, $seeded->name, 'on its own' );

my $name = $other->name;
undef $other;
is(
    scalar $seeded->dbh->selectrow_array(
        'SELECT count(*) FROM pg_database WHERE datname = ?',
        undef, $name
    ),
    0,
    'and is dropped when the test lets it go'
);

done_testing();

sub _count {
    my ( $database, $table ) = @_;

    return
      scalar $database->dbh->selectrow_array("SELECT count(*) FROM $table");
}

1;
