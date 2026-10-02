# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

# Written as now() writes it, to the microsecond; read back in a session zone
# whose offset has minutes, as DBD::Pg hands it over: "17:30:00.123456+05:30".
const my $STAMP        => '2026-05-23 12:00:00.123456+00';
const my $SESSION_ZONE => 'Asia/Kolkata';
const my $INSTANT      => '2026-05-23T12:00:00Z';
const my $LOCAL        => '2026-05-23 12:00 UTC';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the relative times test';
}

# components/timestamp against the rows PostgreSQL returns. The category list
# printed last_activity_at as DBD::Pg rendered it, in datetime and as text:
# not a valid HTML datetime, and in whatever zone the database session had.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;
local $ENV{GPFORUM_DEFAULT_TIMEZONE}          = 'UTC';

my $database = GPForum::Test::PgDatabase->fresh( seed => 1 );
local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;
my $dbh = $database->dbh;
$dbh->do(
    sprintf 'ALTER DATABASE %s SET timezone TO %s',
    $dbh->quote_identifier( $database->name ),
    $dbh->quote($SESSION_ZONE)
);

my ($category_id) = $dbh->selectrow_array(<<'SQL');
SELECT threads.category_id
FROM threads
JOIN categories ON categories.category_id = threads.category_id
JOIN spaces ON spaces.space_id = categories.space_id
WHERE threads.deleted_at IS NULL
  AND threads.moderation_state = 'visible'
  AND threads.visibility = 'public'
  AND categories.deleted_at IS NULL
  AND categories.visibility = 'public'
  AND spaces.visibility = 'public'
LIMIT 1
SQL
ok( $category_id, 'the seed has a public category with a thread' );
$dbh->do( 'UPDATE threads SET last_activity_at = ? WHERE category_id = ?',
    undef, $STAMP, $category_id );

my $client = Test::Mojo->new('GPForum');
$client->get_ok("/c/$category_id");
$client->status_is($HTTP_OK);
my $page  = $client->tx->res->dom;
my @times = $page->find('main time')->each;
ok( scalar @times, 'the category lists its threads with a time' );
for my $time (@times) {
    is( $time->attr('datetime'),
        $INSTANT, 'datetime is the instant, in UTC, whole seconds' );
    is( $time->attr('title'), $LOCAL, 'title is the forum zone time' );
    is( $time->text,          $LOCAL, 'and so is the anonymous text' );
}

done_testing();

1;
