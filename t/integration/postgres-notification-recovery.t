# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use POSIX qw(strftime);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Id;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Test::InterleavedClock;
use GPForum::Test::OfflineStore;
use GPForum::Test::PgDatabase;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

# notifications_default holds this time; the monthly partition migrating
# creates for this UTC month (ADR 0113) holds the other.
const my $IN_DEFAULT    => '2026-05-23T12:00:00Z';
const my $IN_THIS_MONTH => strftime( '%Y-%m-15T12:00:00Z', gmtime );

const my $USER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  q{password_hash, status) VALUES (?, ?, ?, ?, 'x', 'active')};
const my $NOTIFICATION_SQL => join q{ },
  'INSERT INTO notifications (notification_id, recipient_user_id,',
  'source_type, source_id, notification_type, created_at)',
  q{VALUES (?, ?, 'post', ?, 'reply', ?)};
const my $NOTIFICATION_ROWS_SQL =>
  'SELECT count(*) FROM notifications WHERE notification_id = ?';
const my $INBOX_ROWS_SQL => join q{ },
  'SELECT count(*) FROM notification_inbox',
  'WHERE recipient_user_id = ? AND notification_id = ?';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# The dispatcher's recoveries on PostgreSQL.
#
# Another delivery of the same notification commits its notification row,
# and not yet its inbox row, between this delivery's look-up and its insert.
# The insert conflicts on the primary key of the partition the row went to
# -- notifications_default_pkey, notifications_2026_10_pkey -- never on
# notifications_pkey itself: the dispatcher asks X::Conflict, which reads
# the partitions' indexes from the catalog, and completes the delivery with
# the inbox row. Matched on the parent's name alone, the conflict was
# rethrown and the delivery died.
my $database   = GPForum::Test::PgDatabase->fresh;
my $ids        = GPForum::Infrastructure::Id->new;
my $peer       = GPForum::Test::PostgresHarness::connect_dbi( $database->dsn );
my $clock      = GPForum::Test::InterleavedClock->new;
my $dispatcher = GPForum::Service::Notification::Dispatcher->new(
    clock  => $clock,
    schema => $database->schema,
);
my $member = $ids->uuid;
$database->dbh->do( $USER_SQL, undef, $member, 'raced_partition',
    'Raced', 'raced.partition@example.test' );

_raced_notification_row( $IN_DEFAULT,    'the default partition' );
_raced_notification_row( $IN_THIS_MONTH, 'a monthly partition' );
_preferences_offline();

done_testing();

sub _raced_notification_row ( $time, $partition ) {
    my $id     = $ids->uuid;
    my $source = $ids->uuid;
    my $raced  = 0;
    $clock->iso8601($time);
    $clock->before_next_read(
        sub {
            $peer->do( $NOTIFICATION_SQL, undef, $id, $member, $source, $time );
            $raced = 1;
            return;
        }
    );

    my ( $delivered, $error );
    try {
        $delivered = $dispatcher->create_notification(
            {
                notification_id   => $id,
                notification_type => 'reply',
                recipient_user_id => $member,
                source_id         => $source,
                source_type       => 'post',
            }
        );
    }
    catch ($caught) {
        $error = $caught;
    };
    $clock->before_next_read(undef);

    ok( $raced, "the rival's row in $partition went in first" );
    ok( $delivered && $delivered->{ok},
        "a delivery raced in $partition completes" )
      or diag $error;
    ok( $delivered && !$delivered->{duplicate},
        'as the delivery of its inbox row, not a duplicate' );
    is( _count( $NOTIFICATION_ROWS_SQL, $id ),
        1, 'leaving the one notification row' );
    is( _count( $INBOX_ROWS_SQL, $member, $id ),
        1, 'and writing its inbox row' );

    return;
}

# Preferences can only turn a channel off. When they cannot be read the
# in-app notification is delivered, as it is to a member who set none.
sub _preferences_offline {
    my $id        = $ids->uuid;
    my $delivered = GPForum::Service::Notification::Dispatcher->new(
        clock            => $clock,
        preference_store => GPForum::Test::OfflineStore->new,
        schema           => $database->schema,
    )->create_notification(
        {
            notification_id   => $id,
            notification_type => 'reply',
            recipient_user_id => $member,
            source_id         => $ids->uuid,
            source_type       => 'post',
        }
    );

    ok( $delivered->{ok},
        'a notification whose preferences cannot be read is delivered' );
    is( _count( $INBOX_ROWS_SQL, $member, $id ), 1, 'to the inbox' );

    return;
}

sub _count ( $sql, @binds ) {
    my ($count) = $database->dbh->selectrow_array( $sql, undef, @binds );

    return $count;
}

1;
