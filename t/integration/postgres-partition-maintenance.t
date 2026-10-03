# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use DBD::Pg       qw(:async);
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json);
use Mojo::File    qw(path);
use Test::More;
use Time::HiRes ();
use Time::Local qw(timegm);

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Migrate;
use GPForum::Command::PartitionMaintenance;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Id;
use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Test::PgDatabase;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $EXIT_OK         => 0;
const my $EXIT_FAILURE    => 1;
const my $EPOCH_YEAR      => 1900;
const my $MONTHS          => 12;
const my $MID_MONTH       => 15;
const my $TABLES          => 3;
const my $DEFAULT_WINDOW  => 3;
const my $BLOCKED_WAIT_MS => 1_000;
const my $LOCK_TIMEOUT_MS => 2_000;
const my $MIGRATION_038   => 'migrations/038_monthly_log_partitions.sql';
const my $MIGRATION_049   => 'migrations/049_rolling_partitions.sql';
const my @PARENTS         => qw(audit_log event_log notifications);
const my @SEEDED_MONTHS   => qw(2026_09 2026_10 2026_11 2026_12);
const my $USER_ID         => '018f1000-0000-7000-8000-00000000d001';
const my $LOCK_KEY        => 4_021_970_002;
const my $ACTOR           => '018f1000-0000-7000-8000-00000000d002';
const my $SHORT_LOCK_MS   => 200;
const my $SHORT_PAUSE_MS  => 100;
const my $SHORT_ATTEMPTS  => 3;
const my $MILLISECONDS    => 1_000;
const my $SLACK_SECONDS   => 2;
const my $MIGRATE_WAIT_MS => 300;
const my $RELEASE_WAIT_MS => 10_000;
const my $POLLS           => 100;
const my $POLL_SECONDS    => 0.05;

# Months ahead of this one that each case works in, apart from the default
# window and from each other.
const my $LATER_WINDOW   => 5;
const my $ATTACHED_MONTH => 7;
const my $RUN_MONTH      => 8;
const my $LIKE_MONTH     => 9;
const my $PARTITION_OF   => 10;
const my $SKIPPED_MONTH  => 12;
const my $OVERLAP_MONTH  => 14;
const my $EVENT_MONTH    => 16;
const my $RETRY_MONTH    => 17;
const my $BLOCKED_MONTH  => 20;

# March 2027: every month migration 038 named has ended by then.
const my $YEAR_AFTER_038 => 2027;
const my $MARCH_INDEX    => 2;
const my $PARTITIONS_SQL => join q{ },
  'SELECT child.relname FROM pg_inherits inheritance',
  'JOIN pg_class parent ON parent.oid = inheritance.inhparent',
  'JOIN pg_class child ON child.oid = inheritance.inhrelid',
  'WHERE parent.relname = ? ORDER BY child.relname';
const my $RANGE_END_SQL => join q{ },
  q{SELECT substring(pg_get_expr(relpartbound, oid)},
q{FROM 'TO \(''([^'']+)''\)')::timestamptz <= date_trunc('month', now(), 'UTC')},
  'FROM pg_class WHERE relname = ?';
const my $LOCKS_SQL => join q{ },
  'SELECT relation::regclass::text AS relation, relation AS oid, mode,',
  'granted FROM pg_locks WHERE pid = ? AND locktype = ?',
  'ORDER BY 1, 3';
const my $INDEX_FAMILY_SQL => join q{ },
  'SELECT parent_index.relname AS parent_index,',
  'regexp_replace(pg_get_indexdef(child_index.oid), ?, ?, ?) AS definition',
  'FROM pg_index entry',
  'JOIN pg_class child_index ON child_index.oid = entry.indexrelid',
  'LEFT JOIN pg_inherits link ON link.inhrelid = entry.indexrelid',
  'LEFT JOIN pg_class parent_index ON parent_index.oid = link.inhparent',
  'WHERE entry.indrelid = CAST(? AS regclass) ORDER BY 1, 2';
const my $CONSTRAINTS_SQL => join q{ },
  'SELECT own.contype, own.conislocal, own.coninhcount,',
  'pg_get_constraintdef(own.oid) AS definition, parent.conname AS parent',
  'FROM pg_constraint own',
  'LEFT JOIN pg_constraint parent ON parent.oid = own.conparentid',
  'WHERE own.conrelid = CAST(? AS regclass) ORDER BY 1, 4';
const my $COLUMNS_SQL => join q{ },
  'SELECT attname, attislocal, attinhcount, attnotnull,',
  'pg_get_expr(adbin, adrelid) AS default_value',
  'FROM pg_attribute LEFT JOIN pg_attrdef',
  'ON adrelid = attrelid AND adnum = attnum',
  'WHERE attrelid = CAST(? AS regclass) AND attnum > 0',
  'AND NOT attisdropped ORDER BY attnum';
const my $NOTIFICATION_SQL => join q{ },
  'INSERT INTO notifications (notification_id, recipient_user_id,',
  'source_type, notification_type, created_at)',
  q{VALUES (gen_random_uuid(), ?, 'post', 'reply', ?)};
const my $AUDIT_SQL => join q{ },
  'INSERT INTO audit_log (audit_id, action, schema_version,',
  'correlation_id, created_at)',
  q{VALUES (gen_random_uuid(), 'probe.partition', 1, gen_random_uuid(), ?)};

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the partition maintenance test';
}

# ADR 0113 against PostgreSQL 18: the window is computed, a month is created
# and attached beside the parent's writes, what still waits for it waits
# briefly, concurrent runs do not race, and migration 049 clears the months
# migration 038 named outright without deadlocking the application.
subtest 'a fresh install has its current month and no past one' =>
  \&_fresh_install_window;
subtest 'the window is the given month and the two after it' =>
  \&_window_follows_now;
subtest 'ATTACH goes ahead beside an open write to the current month' =>
  \&_attach_beside_open_writer;
subtest 'unpruned reads, and the event write, wait for the attach, briefly' =>
  \&_event_write_beside_attach;
subtest 'the attached partition is the one PARTITION OF would make' =>
  \&_attached_matches_partition_of;
subtest 'a run that finds the maintenance lock held is skipped' =>
  \&_concurrent_run_skips;
subtest 'rows in DEFAULT inside the range are still a conflict' =>
  \&_default_overlap;
subtest '049 on an installation migrated after 2026' =>
  \&_rolling_on_a_later_install;
subtest '049 on an installation that wrote rows into 038 partitions' =>
  \&_rolling_keeps_rows;
subtest '049 beside a transaction writing two of the tables' =>
  \&_rolling_without_deadlock;
subtest 'gpforum-migrate --apply ensures the window' => \&_migrate_window;

done_testing();

sub _fresh_install_window {
    my $database = GPForum::Test::PgDatabase->fresh;
    my $dbh      = $database->dbh;

    for my $parent (@PARENTS) {
        my @past = grep { _ended( $dbh, $_ ) } _months_of( $dbh, $parent );
        is_deeply( \@past, [],
            "$parent has no month partition that ended before this month" );
        for my $offset ( 0 .. $DEFAULT_WINDOW - 1 ) {
            my $name = _partition( $parent, $offset );
            ok( _exists( $dbh, $name ), "$parent has $name" );
        }
    }
    my $registered = $dbh->selectcol_arrayref(
        'SELECT partition_name FROM partition_registry ORDER BY 1');
    is_deeply(
        $registered,
        [ sort map { _months_of( $dbh, $_ ) } @PARENTS ],
        'and partition_registry names exactly the month partitions there are'
    );

    return;
}

sub _window_follows_now {
    my $database  = GPForum::Test::PgDatabase->fresh;
    my $dbh       = $database->dbh;
    my $lifecycle = _lifecycle($dbh);
    my $offset    = $LATER_WINDOW;

    my $result = $lifecycle->ensure_partitions(
        { dbh => $dbh, now_epoch => _month($offset)->{epoch} } );
    ok( $result->{ok}, 'a run five months ahead succeeds' );
    my @expected;
    for my $month ( $offset .. $offset + $DEFAULT_WINDOW - 1 ) {
        push @expected, map { _partition( $_, $month ) } @PARENTS;
    }
    is_deeply(
        [ sort map { $_->{partition_name} } @{ $result->{created} } ],
        [ sort @expected ],
        'creating exactly that month and the two after it, for each table'
    );
    is_deeply(
        $dbh->selectall_arrayref(
            'SELECT partition_name, range_start = CAST(? AS timestamptz),'
              . ' state FROM partition_registry WHERE partition_name = ?',
            undef,
            _month($offset)->{start},
            _partition( 'audit_log', $offset )
        ),
        [ [ _partition( 'audit_log', $offset ), 1, 'created' ] ],
        'each registered as created, with its UTC range'
    );

    my $again = $lifecycle->ensure_partitions(
        { dbh => $dbh, now_epoch => _month($offset)->{epoch} } );
    ok( $again->{ok}, 'the same run again succeeds' );
    is( scalar @{ $again->{created} }, 0, 'creating nothing' );
    is(
        scalar @{ $again->{existing} },
        $TABLES * $DEFAULT_WINDOW,
        'and reporting every partition as existing'
    );

    return;
}

# The case CREATE TABLE ... PARTITION OF could not survive: a transaction
# holding a write to this month's notifications partition, open while the
# maintenance runs. PARTITION OF needs ACCESS EXCLUSIVE on the parent and
# queues behind it; ATTACH needs SHARE UPDATE EXCLUSIVE and does not. What
# does wait, the reads that open DEFAULT, is the next case.
sub _attach_beside_open_writer {
    my $database = GPForum::Test::PgDatabase->fresh;
    my $dbh      = $database->dbh;
    _user($dbh);
    my $writer = GPForum::Test::PostgresHarness::connect_dbi( $database->dsn );
    my $reader = GPForum::Test::PostgresHarness::connect_dbi( $database->dsn );
    my $maintainer =
      GPForum::Test::PostgresHarness::connect_dbi( $database->dsn );
    my $observer =
      GPForum::Test::PostgresHarness::connect_dbi( $database->dsn );

    $writer->do("SET statement_timeout = $LOCK_TIMEOUT_MS");
    $writer->begin_work;
    $writer->do( $NOTIFICATION_SQL, undef, $USER_ID, _month(0)->{middle} );
    ok(
        _holds( $observer, $writer, 'notifications', 'RowExclusiveLock' ),
        'the writer holds its write on notifications, uncommitted'
    );

    my $lifecycle = _lifecycle($maintainer);
    my $plan      = _plan( $lifecycle, 'notifications', $ATTACHED_MONTH );
    $maintainer->do("SET lock_timeout = $LOCK_TIMEOUT_MS");
    $maintainer->begin_work;
    my $attached = eval {
        for my $statement ( @{ $lifecycle->create_statements($plan) } ) {
            $maintainer->do($statement);
        }
        return 1;
    };
    ok( $attached, 'the lifecycle CREATE and ATTACH go through at once' )
      or diag $EVAL_ERROR;
    my ($new_oid) =
      $maintainer->selectrow_array( 'SELECT CAST(? AS regclass)::oid',
        undef, $plan->{partition_name} );
    my $locks = $observer->selectall_arrayref( $LOCKS_SQL, { Slice => {} },
        $maintainer->{pg_pid}, 'relation' );
    note "pg_locks of the attaching transaction:\n" . join "\n", map {
        sprintf '  %s %s %s',
          ( $_->{oid} == $new_oid ? $plan->{partition_name} : $_->{relation} ),
          $_->{mode},
          ( $_->{granted} ? 'granted' : 'waiting' )
    } @{$locks};
    is_deeply(
        _modes( $locks, 'notifications' ),
        [qw(AccessShareLock ShareUpdateExclusiveLock)],
        'on the parent: SHARE UPDATE EXCLUSIVE, and no ACCESS EXCLUSIVE'
    );
    is_deeply( _modes( $locks, 'notifications_default' ),
        ['AccessExclusiveLock'],
        'ACCESS EXCLUSIVE on the DEFAULT partition it scans' );
    ok(
        (
            grep {
                     $_->{oid} == $new_oid
                  && $_->{mode} eq 'AccessExclusiveLock'
            } @{$locks}
        ),
        'and on the new table'
    );
    ok(
        (
            grep { $_ eq 'ShareRowExclusiveLock' }
              @{ _modes( $locks, 'users' ) }
        ),
        'SHARE ROW EXCLUSIVE on users, for the cloned foreign key'
    );

    $reader->do("SET statement_timeout = $BLOCKED_WAIT_MS");
    my $pruned = eval {
        return scalar $reader->selectrow_array(
            'SELECT count(*) FROM notifications'
              . ' WHERE created_at >= CAST(? AS timestamptz)'
              . ' AND created_at < CAST(? AS timestamptz)',
            undef, _month(0)->{start}, _month(1)->{start}
        );
    };
    ok( defined $pruned, q{a read of this month's partition is not held up} )
      or diag $EVAL_ERROR;
    my $unpruned =
      eval { $reader->selectrow_array('SELECT count(*) FROM notifications') };
    like(
        $EVAL_ERROR,
        qr/statement [ ] timeout/msx,
        'a read that scans the DEFAULT partition waits for the commit'
    );
    my $wrote = eval {
        $writer->do( $NOTIFICATION_SQL, undef, $USER_ID, _month(0)->{middle} );
        return 1;
    };
    ok( $wrote, 'the open writer writes again while the ATTACH is uncommitted' )
      or diag $EVAL_ERROR;
    $maintainer->commit;

    my $run = $lifecycle->ensure_partitions(
        { dbh => $maintainer, now_epoch => _month($RUN_MONTH)->{epoch} } );
    ok( $run->{ok}, 'a whole maintenance run succeeds with the writer open' );
    ok( _exists( $maintainer, _partition( 'notifications', $RUN_MONTH ) ),
        'creating notifications for that month' );

    $maintainer->do("SET lock_timeout = $LOCK_TIMEOUT_MS");
    my $blocked = eval {
        $maintainer->do( _partition_of_sql( 'notifications', $BLOCKED_MONTH ) );
        return 1;
    };
    ok( !$blocked, 'where CREATE TABLE ... PARTITION OF still waits for it' );
    like( $EVAL_ERROR, qr/lock [ ] timeout/msx, 'until its lock_timeout' );

    $writer->rollback;
    for my $connection ( $writer, $reader, $maintainer, $observer ) {
        $connection->disconnect;
    }

    return;
}

# What ATTACH does not spare: DEFAULT's ACCESS EXCLUSIVE stops every read
# the planner cannot prune to a month, and the application's event write
# begins with one, the lookup by event_id. So the attach keeps its waits
# short: an open transaction that read DEFAULT holds the month off for a
# lock_timeout per attempt, and after lock_attempts the run reports it and
# leaves it to the next run.
sub _event_write_beside_attach {
    my $database = GPForum::Test::PgDatabase->fresh;
    my $schema   = $database->schema;
    $database->dbh->do("SET statement_timeout = $BLOCKED_WAIT_MS");
    my $maintainer =
      GPForum::Test::PostgresHarness::connect_dbi( $database->dsn );
    my $reader = GPForum::Test::PostgresHarness::connect_dbi( $database->dsn );
    my $ids    = GPForum::Infrastructure::Id->new;
    my $recorder = GPForum::Infrastructure::EventRecorder->new(
        id_service => $ids,
        schema     => $schema,
    );

    my $lifecycle = _lifecycle($maintainer);
    my $plan      = _plan( $lifecycle, 'event_log', $EVENT_MONTH );
    $maintainer->begin_work;
    for my $statement ( @{ $lifecycle->create_statements($plan) } ) {
        $maintainer->do($statement);
    }
    my $went = eval { $recorder->record_event( _event($ids) ); return 1; };
    ok( !$went, 'EventRecorder->record_event waits while the ATTACH is open' );
    like( $EVAL_ERROR, qr/statement [ ] timeout/msx, 'until its timeout' );
    $reader->do("SET statement_timeout = $BLOCKED_WAIT_MS");
    my $by_now = eval {
        $reader->selectrow_array(
                q{SELECT count(*) FROM event_log WHERE created_at >= }
              . q{date_trunc('month', now(), 'UTC')} );
        return 1;
    };
    ok( !$by_now, 'as does a read filtered on now(), pruned only at run time' );
    $maintainer->commit;
    my $recorded = eval { return $recorder->record_event( _event($ids) ); };
    ok( $recorded && $recorded->{event_id}, 'and goes through on the commit' )
      or diag $EVAL_ERROR;

    $reader->begin_work;
    $reader->selectrow_array('SELECT count(*) FROM event_log');
    my $short = GPForum::Service::Operations::PartitionLifecycle->new(
        dbh             => $maintainer,
        lock_attempts   => $SHORT_ATTEMPTS,
        lock_timeout_ms => $SHORT_LOCK_MS,
        retry_pause_ms  => $SHORT_PAUSE_MS,
    );
    my $window = {
        dbh              => $maintainer,
        lookahead_months => 1,
        now_epoch        => _month($RETRY_MONTH)->{epoch},
    };
    my $started = Time::HiRes::time();
    my $run     = $short->ensure_partitions($window);
    my $elapsed = Time::HiRes::time() - $started;
    ok( !$run->{ok},
        'an open transaction that read DEFAULT holds a month off' );
    is_deeply(
        [ map { $_->{partition_name} } @{ $run->{errors} } ],
        [ _partition( 'event_log', $RETRY_MONTH ) ],
        'that table only'
    );
    like(
        $run->{errors}[0]{error},
        qr/lock [ ] timeout\z/msx,
        'on a lock timeout, without a code location'
    );
    is_deeply(
        [ sort map { $_->{partition_name} } @{ $run->{created} } ],
        [ map { _partition( $_, $RETRY_MONTH ) } qw(audit_log notifications) ],
        'while the other tables get theirs'
    );
    my $per_try = ( $SHORT_LOCK_MS + $SHORT_PAUSE_MS ) / $MILLISECONDS;
    cmp_ok(
        $elapsed, '>=',
        $SHORT_ATTEMPTS * $SHORT_LOCK_MS / $MILLISECONDS,
        'having tried lock_attempts times'
    );
    cmp_ok(
        $elapsed, '<',
        $SHORT_ATTEMPTS * $per_try + $SLACK_SECONDS,
        'each wait no longer than lock_timeout'
    );
    $reader->rollback;

    my $next = $short->ensure_partitions($window);
    ok( $next->{ok}, 'the next run, the reader gone, attaches it' );
    $maintainer->disconnect;
    $reader->disconnect;

    return;
}

# Indexes, primary key, foreign key, constraints and columns of a month
# made by CREATE ... LIKE and ATTACH, against one made by PARTITION OF.
sub _attached_matches_partition_of {
    my $database  = GPForum::Test::PgDatabase->fresh;
    my $dbh       = $database->dbh;
    my $lifecycle = _lifecycle($dbh);
    my $run       = $lifecycle->ensure_partitions(
        {
            dbh              => $dbh,
            lookahead_months => 1,
            now_epoch        => _month($LIKE_MONTH)->{epoch}
        }
    );
    ok( $run->{ok}, 'the lifecycle attaches a month' );

    for my $parent (@PARENTS) {
        my $attached = _partition( $parent, $LIKE_MONTH );
        my $made     = _partition( $parent, $PARTITION_OF );
        $dbh->do( _partition_of_sql( $parent, $PARTITION_OF ) );

        my $attached_indexes = _index_family( $dbh, $attached );
        my $parent_indexes   = $dbh->selectcol_arrayref(
            'SELECT indexrelid::regclass::text FROM pg_index'
              . ' WHERE indrelid = CAST(? AS regclass) ORDER BY 1',
            undef, $parent
        );
        is_deeply(
            [ map { $_->[0] // 'unattached' } @{$attached_indexes} ],
            $parent_indexes,
            "$attached has one index per index of $parent, each attached to it"
        );
        is_deeply(
            $attached_indexes,
            _index_family( $dbh, $made ),
            'defined as PARTITION OF defines them'
        );
        is_deeply(
            _rows( $dbh, $CONSTRAINTS_SQL, $attached ),
            _rows( $dbh, $CONSTRAINTS_SQL, $made ),
            'with the same inherited primary key, foreign keys and checks'
        );
        is_deeply(
            _rows( $dbh, $COLUMNS_SQL, $attached ),
            _rows( $dbh, $COLUMNS_SQL, $made ),
            'and the same inherited columns and defaults'
        );
    }
    my ($foreign) = $dbh->selectrow_array(
        q{SELECT parent.conname FROM pg_constraint own}
          . q{ JOIN pg_constraint parent ON parent.oid = own.conparentid}
          . q{ WHERE own.conrelid = CAST(? AS regclass) AND own.contype = 'f'},
        undef,
        _partition( 'notifications', $LIKE_MONTH )
    );
    is(
        $foreign,
        'notifications_recipient_user_id_fkey',
        q{the notifications month carries the parent's foreign key to users}
    );

    return;
}

sub _concurrent_run_skips {
    my $database = GPForum::Test::PgDatabase->fresh;
    my $dbh      = $database->dbh;
    my $holder = GPForum::Test::PostgresHarness::connect_dbi( $database->dsn );
    my $lifecycle = _lifecycle($dbh);
    is( $lifecycle->maintenance_lock_key, $LOCK_KEY, 'the documented key' );

    $holder->selectrow_array( 'SELECT pg_advisory_lock(?)', undef, $LOCK_KEY );
    my $skipped = $lifecycle->ensure_partitions(
        { dbh => $dbh, now_epoch => _month($SKIPPED_MONTH)->{epoch} } );
    ok( $skipped->{ok}, 'a run while another holds the lock is ok' );
    is( $skipped->{skipped}, 1, 'and skipped' );
    ok( !_exists( $dbh, _partition( 'audit_log', $SKIPPED_MONTH ) ),
        'having made nothing' );

    my $command = _run_command(
        sub {
            return GPForum::Command::PartitionMaintenance->new(
                lifecycle => $lifecycle )->run( '--apply', '--json' );
        }
    );
    is( $command->{status}, $EXIT_OK, 'the command exits 0' );
    my $document = decode_json( $command->{output} );
    is_deeply(
        [ @{$document}{qw(status skipped)} ],
        [ 'ok', 1 ],
        'saying ok and skipped'
    );

    {
        local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;
        my $migrate = _run_command(
            sub {
                return GPForum::Command::Migrate->new(
                    partition_lock_wait_ms => $MIGRATE_WAIT_MS )
                  ->run( '--apply', '--json' );
            }
        );
        is( $migrate->{status}, $EXIT_OK,
            'a deploy migrating while a timer run holds it exits 0' );
        is( decode_json( $migrate->{output} )->{partitions}{skipped},
            1, 'its window step skipped, once its wait ran out' );

        $holder->do( "SELECT pg_sleep(1), pg_advisory_unlock($LOCK_KEY)",
            { pg_async => PG_ASYNC } );
        my $waited = _run_command(
            sub {
                return GPForum::Command::Migrate->new(
                    partition_lock_wait_ms => $RELEASE_WAIT_MS )
                  ->run( '--apply', '--json' );
            }
        );
        $holder->pg_result;
        is( $waited->{status}, $EXIT_OK,
            'a migrate whose wait outlasts the other run exits 0' );
        is( decode_json( $waited->{output} )->{partitions}{skipped},
            0, 'having waited for the lock and checked the window itself' );
        $holder->selectrow_array( 'SELECT pg_advisory_lock(?)',
            undef, $LOCK_KEY );
    }

    $holder->selectrow_array( 'SELECT pg_advisory_unlock(?)', undef,
        $LOCK_KEY );
    my $after = $lifecycle->ensure_partitions(
        { dbh => $dbh, now_epoch => _month($SKIPPED_MONTH)->{epoch} } );
    is(
        scalar @{ $after->{created} },
        $TABLES * $DEFAULT_WINDOW,
        'once it is released, the run does the work'
    );
    my ($held) = $dbh->selectrow_array(
            q{SELECT count(*) FROM pg_locks WHERE locktype = 'advisory'}
          . ' AND pid = pg_backend_pid()' );
    is( $held, 0, 'and lets go of the lock when it is done' );
    $holder->disconnect;

    return;
}

sub _default_overlap {
    my $database  = GPForum::Test::PgDatabase->fresh;
    my $dbh       = $database->dbh;
    my $lifecycle = _lifecycle($dbh);
    $dbh->do( $AUDIT_SQL, undef, _month($OVERLAP_MONTH)->{middle} );

    my $result = $lifecycle->ensure_partitions(
        {
            dbh              => $dbh,
            lookahead_months => 1,
            now_epoch        => _month($OVERLAP_MONTH)->{epoch}
        }
    );
    ok( !$result->{ok}, 'a row of that month in audit_log_default fails it' );
    is(
        $result->{conflicts}[0]{partition_name},
        _partition( 'audit_log', $OVERLAP_MONTH ),
        'as a conflict on that month'
    );
    is( $result->{conflicts}[0]{conflicting_rows}, 1, 'counting the row' );
    is_deeply(
        [ sort map { $_->{partition_name} } @{ $result->{created} } ],
        [
            map { _partition( $_, $OVERLAP_MONTH ) }
              qw(event_log notifications)
        ],
        'while the other tables get theirs'
    );

    # The probe sees the row first. Asked anyway -- a row written between
    # the probe and the ATTACH -- PostgreSQL refuses in words the lifecycle
    # classifies as the same conflict, and the transaction takes the new
    # table with it.
    my $plan = _plan( $lifecycle, 'audit_log', $OVERLAP_MONTH );
    $dbh->begin_work;
    my $done = eval {
        for my $statement ( @{ $lifecycle->create_statements($plan) } ) {
            $dbh->do($statement);
        }
        return 1;
    };
    my $refusal = $EVAL_ERROR;
    $dbh->rollback;
    ok( !$done, 'PostgreSQL refuses the ATTACH itself' );
    like(
        $refusal,
        qr/default [ ] partition .* violated [ ] by [ ] some [ ] row/msx,
        'in the words the lifecycle classifies as an overlap'
    );
    ok(
        !_exists( $dbh, _partition( 'audit_log', $OVERLAP_MONTH ) ),
        'and the rolled-back CREATE leaves no table behind'
    );

    return;
}

# A fresh install in 2027 gets 038's four months of 2026, empty: 049 drops
# them, at the cut-off the test gives it, and the window step creates the
# install's own month before its first write.
sub _rolling_on_a_later_install {
    my $database = GPForum::Test::PgDatabase->fresh;
    my $dbh      = $database->dbh;
    _replay_038($dbh);
    ok( _exists( $dbh, 'audit_log_2026_09' ), q{038's state is back} );
    my $cutoff = _later_cutoff();

    _replay_049( $dbh, $cutoff->{start} );
    for my $parent (@PARENTS) {
        is_deeply(
            [
                grep { _ends_by( $dbh, $_, $cutoff->{start} ) }
                  _months_of( $dbh, $parent )
            ],
            [],
            "every empty $parent month before $cutoff->{start} is dropped"
        );
    }
    is(
        scalar $dbh->selectrow_array(
            q{SELECT count(*) FROM partition_registry}
              . q{ WHERE range_end <= CAST(? AS timestamptz)},
            undef,
            $cutoff->{start}
        ),
        0,
        'with their registry rows'
    );

    my $result = _lifecycle($dbh)
      ->ensure_partitions( { dbh => $dbh, now_epoch => $cutoff->{epoch} } );
    ok( $result->{ok}, 'the window step then runs at that date' );
    _user($dbh);
    $dbh->do( $NOTIFICATION_SQL, undef, $USER_ID, $cutoff->{middle} );
    is(
        scalar $dbh->selectrow_array(
            'SELECT tableoid::regclass::text FROM notifications'
              . ' WHERE created_at = CAST(? AS timestamptz)',
            undef,
            $cutoff->{middle}
        ),
        "notifications_$cutoff->{suffix}",
        'and the first write of that month lands in its own partition'
    );

    return;
}

# The owner's database in October 2026: 038's September may hold rows. 049
# drops the empty Septembers and keeps the one with a row, and the months
# from the current one on are left alone.
sub _rolling_keeps_rows {
    my $database = GPForum::Test::PgDatabase->fresh;
    my $dbh      = $database->dbh;
    _replay_038($dbh);
    _user($dbh);
    $dbh->do( $NOTIFICATION_SQL, undef, $USER_ID, '2026-09-15T12:00:00Z' );
    my $writer = GPForum::Test::PostgresHarness::connect_dbi( $database->dsn );
    $writer->begin_work;
    $writer->do( $NOTIFICATION_SQL, undef, $USER_ID, '2026-10-15T12:00:00Z' );

    my $started = Time::HiRes::time();
    _replay_049( $dbh, '2026-10-01T00:00:00Z' );
    cmp_ok(
        Time::HiRes::time() - $started,
        '<',
        $LOCK_TIMEOUT_MS / $MILLISECONDS,
        'notifications, with no empty past month, is not locked at all'
    );
    $writer->rollback;
    $writer->disconnect;
    ok(
        _exists( $dbh, 'notifications_2026_09' ),
        'the September partition holding a row is kept'
    );
    is(
        scalar $dbh->selectrow_array(
                q{SELECT count(*) FROM partition_registry}
              . q{ WHERE partition_name = 'notifications_2026_09'}
        ),
        1,
        'with its registry row'
    );

    for my $empty (qw(audit_log_2026_09 event_log_2026_09)) {
        ok( !_exists( $dbh, $empty ), "the empty $empty is dropped" );
    }
    for
      my $kept ( map { "audit_log_$_" } @SEEDED_MONTHS[ 1 .. $#SEEDED_MONTHS ] )
    {
        ok( _exists( $dbh, $kept ), "$kept, not yet past then, is kept" );
    }

    return;
}

# The deadlock the first draft of 049 had: holding audit_log's ACCESS
# EXCLUSIVE while waiting for a parent an application transaction held,
# which then wanted audit_log. Each parent is now a transaction of its own,
# so the application's second write goes through and 049 finishes after it.
sub _rolling_without_deadlock {
    my $database = GPForum::Test::PgDatabase->fresh;
    my $dbh      = $database->dbh;
    _replay_038($dbh);
    _user($dbh);
    my $cutoff = _later_cutoff();
    my $application =
      GPForum::Test::PostgresHarness::connect_dbi( $database->dsn );
    my $migrator =
      GPForum::Test::PostgresHarness::connect_dbi( $database->dsn );
    my $observer =
      GPForum::Test::PostgresHarness::connect_dbi( $database->dsn );

    $application->do("SET statement_timeout = $LOCK_TIMEOUT_MS");
    $application->begin_work;
    $application->do( $NOTIFICATION_SQL, undef, $USER_ID, _month(0)->{middle} );
    $migrator->do( 'SELECT set_config(?, ?, false)',
        undef, 'gpforum.partition_cutoff', $cutoff->{start} );
    $migrator->do( path($MIGRATION_049)->slurp, { pg_async => PG_ASYNC } );
    ok(
        _waits_for( $observer, $migrator, 'notifications' ),
        '049 reaches notifications, which the application holds'
    );
    my $audit_write = eval {
        $application->do( $AUDIT_SQL, undef, _month(0)->{middle} );
        return 1;
    };
    ok( $audit_write,
        'the application then writes audit_log, 049 done with it' )
      or diag $EVAL_ERROR;
    $application->commit;
    my $finished = eval {
        local $SIG{__WARN__} = sub { return; };
        $migrator->pg_result;
        return 1;
    };
    ok( $finished, 'and 049 finishes once the application commits' )
      or diag $EVAL_ERROR;
    ok(
        !_exists( $dbh, 'notifications_2026_09' ),
        'dropping the empty notifications months'
    );
    for my $connection ( $application, $migrator, $observer ) {
        $connection->disconnect;
    }

    return;
}

sub _migrate_window {
    my $database = GPForum::Test::PgDatabase->fresh;
    my $dbh      = $database->dbh;
    local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;
    my $final_month = $DEFAULT_WINDOW - 1;
    _drop_month( $dbh, $final_month );

    my $without = _run_command(
        sub {
            return GPForum::Command::Migrate->new->run( '--apply',
                '--no-partitions' );
        }
    );
    is( $without->{status}, $EXIT_OK, '--apply --no-partitions exits 0' );
    ok( !_exists( $dbh, _partition( 'audit_log', $final_month ) ),
        'and leaves the missing month missing' );

    my $with = _run_command(
        sub { return GPForum::Command::Migrate->new->run('--apply') } );
    is( $with->{status}, $EXIT_OK, '--apply exits 0' );
    for my $parent (@PARENTS) {
        ok( _exists( $dbh, _partition( $parent, $final_month ) ),
            "and creates the missing $parent month" );
    }
    my $created = _partition( 'audit_log', $final_month );
    like( $with->{output},
        qr/^partition [ ] created [ ] \Q$created\E [ ] range=/msx,
        'saying so' );
    is(
        _run_command(
            sub { return GPForum::Command::Migrate->new->run('--apply') }
        )->{output},
        q{},
        'a second --apply prints nothing'
    );

    _drop_month( $dbh, $final_month );
    $dbh->do( $AUDIT_SQL, undef, _month($final_month)->{middle} );
    my $blocked = _run_command(
        sub { return GPForum::Command::Migrate->new->run('--apply') } );
    is( $blocked->{status}, $EXIT_FAILURE,
        'a row in DEFAULT inside the window fails --apply' );
    like(
        $blocked->{errors},
        qr/partition-maintenance[.]md/msx,
        'pointing at the runbook'
    );

    return;
}

# --- helpers ---------------------------------------------------------------

sub _lifecycle {
    my ($dbh) = @_;

    return GPForum::Service::Operations::PartitionLifecycle->new(
        dbh             => $dbh,
        lock_timeout_ms => $LOCK_TIMEOUT_MS,
    );
}

sub _plan {
    my ( $lifecycle, $parent, $offset ) = @_;

    my ($plan) =
      grep { $_->{table_name} eq $parent }
      @{ $lifecycle->plan_window( { now_epoch => _month($offset)->{epoch} } ) };

    return $plan;
}

# Migration 038's own file again, which recreates its months of 2026 where
# 049 dropped them: the state an installation was in before 049. Its
# "already exists, skipping" notices are not this test's business.
sub _replay_038 {
    my ($dbh) = @_;

    local $SIG{__WARN__} = sub { return; };
    $dbh->do( path($MIGRATION_038)->slurp );

    return;
}

# Migration 049's own file, replayed with gpforum.partition_cutoff standing
# in for the current month.
sub _replay_049 {
    my ( $dbh, $cutoff ) = @_;

    local $SIG{__WARN__} = sub { return; };
    $dbh->do(
        'SELECT set_config(?, ?, false)', undef,
        'gpforum.partition_cutoff',       $cutoff
    );
    $dbh->do( path($MIGRATION_049)->slurp );
    $dbh->do(
        'SELECT set_config(?, ?, false)', undef,
        'gpforum.partition_cutoff',       q{}
    );

    return;
}

sub _partition_of_sql {
    my ( $parent, $offset ) = @_;

    return sprintf q{CREATE TABLE %s PARTITION OF %s FOR VALUES FROM}
      . q{ (TIMESTAMPTZ '%s') TO (TIMESTAMPTZ '%s')},
      _partition( $parent, $offset ), $parent, _month($offset)->{start},
      _month( $offset + 1 )->{start};
}

sub _drop_month {
    my ( $dbh, $offset ) = @_;

    for my $parent (@PARENTS) {
        my $name = _partition( $parent, $offset );
        $dbh->do("DROP TABLE IF EXISTS $name");
        $dbh->do( 'DELETE FROM partition_registry WHERE partition_name = ?',
            undef, $name );
    }

    return;
}

# March of the year after the last month 038 named, or the month after this
# one if that is later: a date at which every 038 month has ended.
sub _later_cutoff {
    my $march = timegm( 0, 0, 0, $MID_MONTH, $MARCH_INDEX, $YEAR_AFTER_038 );
    my $next  = _month(1);

    return $next->{epoch} > $march ? $next : _month_at($march);
}

sub _month {
    my ($offset) = @_;

    my ( undef, undef, undef, undef, $month, $year ) = gmtime;
    my $index = ( $year + $EPOCH_YEAR ) * $MONTHS + $month + $offset;

    return _month_at(
        timegm(
            0, 0, 0, $MID_MONTH, $index % $MONTHS, int( $index / $MONTHS )
        )
    );
}

sub _month_at {
    my ($epoch) = @_;

    my ( undef, undef, undef, undef, $month, $year ) = gmtime $epoch;
    $year += $EPOCH_YEAR;

    return {
        epoch  => $epoch,
        middle => sprintf( '%04d-%02d-15T12:00:00Z', $year, $month + 1 ),
        start  => sprintf( '%04d-%02d-01T00:00:00Z', $year, $month + 1 ),
        suffix => sprintf( '%04d_%02d',              $year, $month + 1 ),
    };
}

sub _partition {
    my ( $parent, $offset ) = @_;

    return "${parent}_" . _month($offset)->{suffix};
}

sub _months_of {
    my ( $dbh, $parent ) = @_;

    return
      grep { /_\d{4}_\d\d\z/msx }
      @{ $dbh->selectcol_arrayref( $PARTITIONS_SQL, undef, $parent ) };
}

sub _ended {
    my ( $dbh, $name ) = @_;

    return scalar $dbh->selectrow_array( $RANGE_END_SQL, undef, $name );
}

sub _ends_by {
    my ( $dbh, $name, $cutoff ) = @_;

    return scalar $dbh->selectrow_array(
        q{SELECT substring(pg_get_expr(relpartbound, oid)}
          . q{ FROM 'TO \(''([^'']+)''\)')::timestamptz}
          . q{ <= CAST(? AS timestamptz) FROM pg_class WHERE relname = ?},
        undef, $cutoff, $name
    );
}

sub _exists {
    my ( $dbh, $name ) = @_;

    return
      scalar $dbh->selectrow_array( 'SELECT to_regclass(?) IS NOT NULL',
        undef, $name );
}

sub _waits_for {
    my ( $observer, $waiter, $relation ) = @_;

    for ( 1 .. $POLLS ) {
        my $waiting = grep {
                 $_->{relation} eq $relation
              && $_->{mode} eq 'AccessExclusiveLock'
              && !$_->{granted}
          } @{
            $observer->selectall_arrayref( $LOCKS_SQL, { Slice => {} },
                $waiter->{pg_pid}, 'relation' )
          };
        return 1 if $waiting;
        Time::HiRes::sleep($POLL_SECONDS);
    }

    return 0;
}

sub _event {
    my ($ids) = @_;

    my $aggregate = $ids->uuid;

    return (
        actor_id          => $ACTOR,
        aggregate_id      => $aggregate,
        aggregate_type    => 'category',
        aggregate_version => 1,
        event_id          => $ids->uuid,
        event_type        => 'category.updated',
        idempotency_key   => "category.updated:$aggregate",
        payload           => { category_id => $aggregate },
    );
}

sub _holds {
    my ( $observer, $holder, $relation, $mode ) = @_;

    return grep { $_->{relation} eq $relation && $_->{mode} eq $mode } @{
        $observer->selectall_arrayref( $LOCKS_SQL, { Slice => {} },
            $holder->{pg_pid}, 'relation' )
    };
}

sub _modes {
    my ( $locks, $relation ) = @_;

    return [
        map  { $_->{mode} }
        grep { $_->{relation} eq $relation } @{$locks}
    ];
}

# Each index with the parent index it is attached to, its own name and its
# table's taken out of its definition so two months compare.
sub _index_family {
    my ( $dbh, $table ) = @_;

    return $dbh->selectall_arrayref( $INDEX_FAMILY_SQL, undef,
        "\Q$table\E", 'MONTH', 'g', $table );
}

sub _rows {
    my ( $dbh, $sql, $table ) = @_;

    return $dbh->selectall_arrayref( $sql, undef, $table );
}

sub _user {
    my ($dbh) = @_;

    $dbh->do(
        q{INSERT INTO users (id, username, display_name, email_normalized,}
          . q{ password_hash, status) VALUES (?, 'partitioned',}
          . q{ 'Partitioned', 'partitioned@example.test', 'x', 'active')}
          . q{ ON CONFLICT DO NOTHING},
        undef, $USER_ID
    );

    return;
}

sub _run_command {
    my ($code) = @_;

    my $output = q{};
    my $errors = q{};
    open my $stdout, '>', \$output or croak 'capture stdout';
    open my $stderr, '>', \$errors or croak 'capture stderr';
    my $status;
    {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $status = $code->();
    }
    close $stdout or croak 'close stdout';
    close $stderr or croak 'close stderr';

    return { errors => $errors, output => $output, status => $status };
}

1;
