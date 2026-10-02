# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Log;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Id;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Service::Realtime::PgNotifier;
use GPForum::Test::FailingNotificationReadability;
use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# A mention is delivered inside the command log's transaction, and its badge
# is counted there too. A count that failed in the database aborted that
# transaction: raised, it rolled the post back; caught, it left the post to
# a COMMIT PostgreSQL turns into a rollback. The count runs in a savepoint,
# so the post and its notification commit without a badge.
my $database = GPForum::Test::PgDatabase->fresh;
my $schema   = $database->schema;
my $dbh      = $schema->storage->dbh;
my $ids      = GPForum::Infrastructure::Id->new;
my $member   = $ids->uuid;
$dbh->do(
    q{INSERT INTO users (id, username, display_name, email_normalized,}
      . q{ password_hash, status) VALUES (?, 'badge_reader', 'Badge Reader',}
      . q{ 'badge.reader@example.test', 'x', 'active')},
    undef, $member
);

my $readability =
  GPForum::Test::FailingNotificationReadability->new( fail_in_sql => 1 );
my $log        = Mojo::Log->new( level => 'warn' );
my $warnings   = $log->capture('warn');
my $dispatcher = GPForum::Service::Notification::Dispatcher->new(
    badge_errors      => {},
    logger            => $log,
    readability       => $readability,
    realtime_notifier =>
      GPForum::Service::Realtime::PgNotifier->new( schema => $schema ),
    schema => $schema,
    stats  => { badge_failures => 0 },
);

my $delivered = eval {
    return $schema->txn_do(
        sub {
            my $result = $dispatcher->create_notification(
                {
                    notification_type => 'mention',
                    recipient_user_id => $member,
                    source_id         => $ids->uuid,
                    source_type       => 'post',
                }
            );

            # The rest of the post's work, after the mention.
            $schema->storage->dbh->do('SELECT 1');

            return $result;
        }
    );
};
ok( $delivered, 'the outer transaction carries on past a failed badge count' )
  or diag $EVAL_ERROR;
ok( $delivered && $delivered->{ok}, 'the delivery answers ok' );
ok( $delivered && !defined $delivered->{unread_count},
    'without an unread count' );
is( $dispatcher->snapshot->{badge_failures},
    1, 'the badge that could not be counted is counted' );

# DBI appends the statement and its bind values -- the member's id -- to
# the error's line. Logged with them, each member's failure was a new
# message, and /metrics would have said whose count failed.
like(
    "$warnings",
    qr/badge [ ] not [ ] sent: [ ] .* division [ ] by [ ] zero $/msx,
    'the failed count is logged with PostgreSQL\'s error'
);
unlike(
    "$warnings",
    qr/ParamValues|\Q$member\E/msx,
    'without the statement and the member\'s id DBI appends'
);
like(
    $dispatcher->snapshot->{last_badge_error}{message},
    qr/division [ ] by [ ] zero \z/msx,
    'which is the last badge failure the snapshot reports'
);

my ($stored) = $dbh->selectrow_array(
    'SELECT count(*) FROM notification_inbox WHERE recipient_user_id = ?',
    undef, $member );
is( $stored, 1, 'the notification committed with the outer transaction' );

# A NOTIFY that PostgreSQL refuses aborts the transaction too, though the
# notifier catches the error and answers ok => 0: the dispatcher raises it
# inside the savepoint so that the savepoint, not the post, is rolled back.
# An empty channel name is one pg_notify refuses.
my $notify_member = $ids->uuid;
$dbh->do(
    q{INSERT INTO users (id, username, display_name, email_normalized,}
      . q{ password_hash, status) VALUES (?, 'notify_reader', 'Notify Reader',}
      . q{ 'notify.reader@example.test', 'x', 'active')},
    undef, $notify_member
);
my $refused_notify = GPForum::Service::Notification::Dispatcher->new(
    realtime_notifier => GPForum::Service::Realtime::PgNotifier->new(
        channel => q{},
        schema  => $schema,
    ),
    schema => $schema,
    stats  => { badge_failures => 0 },
);
my $notified = eval {
    return $schema->txn_do(
        sub {
            my $result = $refused_notify->create_notification(
                {
                    notification_type => 'mention',
                    recipient_user_id => $notify_member,
                    source_id         => $ids->uuid,
                    source_type       => 'post',
                }
            );
            $schema->storage->dbh->do('SELECT 1');

            return $result;
        }
    );
};
ok( $notified, 'the outer transaction carries on past a refused NOTIFY' )
  or diag $EVAL_ERROR;
is( $notified && $notified->{unread_count},
    1, 'the delivery keeps the unread count it read' );
is( $refused_notify->snapshot->{badge_failures},
    1, 'the refused NOTIFY is counted' );
my ($notified_rows) = $dbh->selectrow_array(
    'SELECT count(*) FROM notification_inbox WHERE recipient_user_id = ?',
    undef, $notify_member );
is( $notified_rows, 1,
    'the notification committed although its NOTIFY was refused' );

done_testing();

1;
