# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::PartitionLifecycle;

use Carp qw(croak);
use Const::Fast;
use English     qw(-no_match_vars);
use POSIX       qw(strftime);
use Time::HiRes ();
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

const my $EPOCH_YEAR_OFFSET => 1900;
const my $MONTHS_PER_YEAR   => 12;
const my $POLICY_VERSION    => 1;
const my $SECONDS_PER_DAY   => 86_400;
const my $DEFAULT_LOOKAHEAD => 3;
const my $MILLISECONDS      => 1_000;

# Every lock a month's transaction waits for stalls the traffic queued behind
# it: an unpruned read of the parent -- EventRecorder's lookup by event_id,
# the audit chain tip -- opens the DEFAULT partition, and waits while the
# ATTACH waits for, or holds, its ACCESS EXCLUSIVE. So each wait is short and
# a month gets a few attempts with a pause between them, in which the queue
# drains, rather than one long wait.
const my $DEFAULT_LOCK_TIMEOUT  => 500;
const my $DEFAULT_LOCK_ATTEMPTS => 5;
const my $DEFAULT_RETRY_PAUSE   => 1_000;
const my $LOCK_TIMEOUT_STATE    => '55P03';
const my $LOCK_TIMEOUT_PATTERN  => qr/ lock [ ] timeout /msx;
const my $DEFAULT_SUFFIX        => '_default';
const my $PARTITION_KEY         => 'created_at';

# The daily timer and every migrate keep three months ahead, so a horizon
# under 45 days means the runs have stopped for weeks. Degraded, not failed:
# writes still land, in the DEFAULT partition, and the fix is an operator's.
const my $HORIZON_WARNING_DAYS => 45;
const my $HORIZON_SQL => join q{ },
  'SELECT parent.relname AS table_name,',
  'extract(epoch FROM max(substring(pg_get_expr(child.relpartbound, child.oid)',
  q{FROM 'TO \(''([^'']+)''\)')::timestamptz)) AS horizon_epoch},
  'FROM pg_inherits inheritance',
  'JOIN pg_class parent ON parent.oid = inheritance.inhparent',
  'JOIN pg_class child ON child.oid = inheritance.inhrelid',
  'JOIN pg_namespace space ON space.oid = parent.relnamespace',
  'WHERE space.nspname = current_schema() AND parent.relname = ANY (?)',
  'GROUP BY parent.relname';
const my @PARTITIONED_TABLES => qw(
  audit_log
  event_log
  notifications
);
const my %IS_PARTITIONED_TABLE => map { $_ => 1 } @PARTITIONED_TABLES;
const my %NEXT_STATE => (
    planned  => 'created',
    created  => 'detached',
    detached => 'archived',
    archived => 'dropped',
);
const my $IDENTIFIER_PATTERN => qr/\A [a-z] [a-z0-9_]{2,61} \z/msx;
const my $MONTH_SUFFIX_PATTERN =>
  qr/[_] [0-9]{4} [_] (?: 0[1-9] | 1[0-2] ) \z/msx;
const my $BOUND_PATTERN =>
qr/\A [0-9]{4} - [0-9]{2} - [0-9]{2} [ ] [0-9]{2} : [0-9]{2} : [0-9]{2} [+] 00 \z/msx;
const my $POSITIVE_INTEGER_PATTERN => qr/\A [1-9] [0-9]{0,2} \z/msx;
const my $DEFAULT_CONFLICT_PATTERN =>
  qr/ default [ ] partition | violated [ ] by [ ] some [ ] row /msx;

# A month is created as a table of its own and then attached, in one
# transaction. CREATE TABLE ... PARTITION OF takes ACCESS EXCLUSIVE on the
# parent, so it queued behind every open transaction on notifications,
# event_log or audit_log and stopped every read and write queued behind it.
# ATTACH PARTITION takes SHARE UPDATE EXCLUSIVE on the parent, which neither
# reads nor writes conflict with; ACCESS EXCLUSIVE falls on the new table and
# on the DEFAULT partition it scans. That last one still stops every read the
# planner cannot prune to a month, since such a read opens DEFAULT too, and
# with it the application's event and audit writes, which begin with one;
# only a write routed straight to its month, or a read pruned at plan time,
# goes past. Hence the short lock_timeout above. Measured on PostgreSQL 18 in
# t/integration/postgres-partition-maintenance.t. INDEXES are left out on
# purpose: ATTACH builds each of the parent's partitioned indexes on the new
# table and attaches it, named as PARTITION OF names them, so LIKE copying
# them too would only give it a second set to reconcile.
const my $CREATE_TEMPLATE => join q{ },
  'CREATE TABLE %s (LIKE %s',
  'INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING STORAGE',
  'INCLUDING COMMENTS INCLUDING COMPRESSION INCLUDING GENERATED)';
const my $ATTACH_TEMPLATE => join q{ },
  'ALTER TABLE %s ATTACH PARTITION %s',
  'FOR VALUES FROM (%s) TO (%s)';

# The remediation runs with the DEFAULT partition detached, inside a window
# that already holds ACCESS EXCLUSIVE, so the one-statement form is the
# clearer one to hand an operator.
const my $PARTITION_OF_TEMPLATE => join q{ },
  'CREATE TABLE IF NOT EXISTS %s', 'PARTITION OF %s',
  'FOR VALUES FROM (%s) TO (%s)';

# One fixed key for every maintenance run, beside the migration runner's
# 4_021_970_001. Session-level, because a run is one transaction per
# partition. Two nodes' timers and a deploy's migrate can overlap; the run
# that does not get the lock reports itself skipped and does nothing, since
# the run holding it is doing the same work.
const my $MAINTENANCE_LOCK_KEY => 4_021_970_002;
const my $TRY_LOCK_SQL         => 'SELECT pg_try_advisory_lock(?)';
const my $WAIT_LOCK_SQL        => 'SELECT pg_advisory_lock(?)';
const my $UNLOCK_SQL           => 'SELECT pg_advisory_unlock(?)';
const my $REGISTRY_UPSERT => join q{ },
  'INSERT INTO partition_registry',
  '(table_name, partition_name, range_start, range_end, state)',
  'VALUES (?, ?, CAST(? AS timestamptz), CAST(? AS timestamptz), ?)',
  'ON CONFLICT (table_name, partition_name) DO UPDATE SET',
  'range_start = EXCLUDED.range_start,',
  'range_end = EXCLUDED.range_end,',
  'state = EXCLUDED.state';
const my $COUNT_TEMPLATE => join q{ },
  'SELECT count(*) FROM %s',
  'WHERE %s >= CAST(? AS timestamptz)',
  'AND %s < CAST(? AS timestamptz)';

has dbh                  => undef;
has lock_attempts        => sub { return $DEFAULT_LOCK_ATTEMPTS; };
has lock_timeout_ms      => sub { return $DEFAULT_LOCK_TIMEOUT; };
has lock_wait_ms         => 0;
has lookahead_months     => sub { return $DEFAULT_LOOKAHEAD; };
has retry_pause_ms       => sub { return $DEFAULT_RETRY_PAUSE; };
has schema               => undef;
has statement_timeout_ms => undef;

sub partitioned_tables {
    return [@PARTITIONED_TABLES];
}

sub policy_version {
    return $POLICY_VERSION;
}

sub partition_key ( $self, $table ) {
    $self->validate_table_name($table);

    return $PARTITION_KEY;
}

sub validate_table_name ( $, $table ) {
    my $name = defined $table ? $table : q{};
    croak "partition lifecycle: unsafe table identifier '$name'"
      if $name !~ $IDENTIFIER_PATTERN;
    croak "partition lifecycle: '$name' is not a partitioned table"
      if !exists $IS_PARTITIONED_TABLE{$name};

    return $name;
}

sub validate_partition_name ( $self, $table, $partition ) {
    my $parent = $self->validate_table_name($table);
    my $name   = defined $partition ? $partition : q{};
    croak "partition lifecycle: unsafe partition identifier '$name'"
      if $name !~ $IDENTIFIER_PATTERN;
    croak "partition lifecycle: '$name' is not a month partition of '$parent'"
      if $name !~ /\A \Q$parent\E $MONTH_SUFFIX_PATTERN/msx;

    return $name;
}

sub default_partition_name ( $self, $table ) {
    my $parent = $self->validate_table_name($table);

    return $parent . $DEFAULT_SUFFIX;
}

sub plan_window ( $self, $input ) {
    $input ||= {};
    my $horizon = $input->{horizon_months} || 1;
    my @months  = $self->_month_starts( $input->{now_epoch}, $horizon );
    my @plans;
    for my $month (@months) {
        push @plans, $self->_plans_for_month($month);
    }

    return \@plans;
}

sub maintenance_lock_key {
    return $MAINTENANCE_LOCK_KEY;
}

sub create_statements ( $self, $plan ) {
    my $table = $self->validate_table_name( $plan->{table_name} );
    my $partition =
      $self->validate_partition_name( $table, $plan->{partition_name} );

    return [
        sprintf( $CREATE_TEMPLATE, $partition, $table ),
        sprintf( $ATTACH_TEMPLATE,
            $table,
            $partition,
            _bound_literal( $plan->{range_start_sql} ),
            _bound_literal( $plan->{range_end_sql} ) ),
    ];
}

sub create_statement ( $self, $plan ) {
    return join q{; }, @{ $self->create_statements($plan) };
}

sub remediation_steps ( $self, $plan ) {
    my $table   = $self->validate_table_name( $plan->{table_name} );
    my $default = $self->default_partition_name($table);
    my $range   = $self->_range_predicate($plan);

    return [
        'BEGIN;',
        sprintf( 'ALTER TABLE %s DETACH PARTITION %s;', $table, $default ),
        $self->_partition_of_statement($plan) . q{;},
        sprintf(
            'INSERT INTO %s SELECT * FROM %s WHERE %s;',
            $table, $default, $range
        ),
        sprintf( 'DELETE FROM %s WHERE %s;', $default, $range ),
        sprintf(
            'ALTER TABLE %s ATTACH PARTITION %s DEFAULT;',
            $table, $default
        ),
        'COMMIT;',
    ];
}

sub conflict_report ( $self, $plan, $rows, $detail = undef ) {
    my %report = (
        %{ $self->_evidence($plan) },
        conflicting_rows => defined $rows ? $rows : -1,
        error            => 'default_partition_overlap',
        remediation      => $self->remediation_steps($plan),
    );
    $report{message} = _conflict_message( \%report );
    if ( defined $detail ) {
        $report{detail} = $detail;
    }

    return \%report;
}

sub ensure_partitions ( $self, $input ) {
    $input ||= {};
    my $lookahead = $self->_lookahead($input);
    my $handle    = $self->_require_dbh($input);
    my $result    = _empty_result( $lookahead, $input->{apply} );
    my $plans     = $self->plan_window(
        {
            horizon_months => $lookahead,
            now_epoch      => $input->{now_epoch} || time,
        }
    );
    $self->_apply_lock_timeout( $handle, $result );
    $self->_apply_statement_timeout( $handle, $result );
    if ( !$self->_take_lock( $handle, $result ) ) {
        $result->{skipped} = 1;
        return $result;
    }
    my $done = eval {
        for my $plan ( @{$plans} ) {
            $self->_ensure_partition( $handle, $plan, $result );
        }
        return 1;
    };
    my $failure = $EVAL_ERROR;
    _release_lock( $handle, $result );
    croak $failure if !$done;
    $result->{ok} =
      ( @{ $result->{conflicts} } || @{ $result->{errors} } ) ? 0 : 1;

    return $result;
}

# Plan mode writes nothing and takes no lock. A query that cannot even ask for
# the lock is a whole-run problem and propagates.
sub _take_lock ( $self, $handle, $result ) {
    return 1                                         if !$result->{applied};
    return $self->_wait_for_lock( $handle, $result ) if $self->lock_wait_ms;

    my ($taken) =
      $handle->selectrow_array( $TRY_LOCK_SQL, undef, $MAINTENANCE_LOCK_KEY );
    $result->{locked} = $taken ? 1 : 0;

    return $result->{locked};
}

# migrate waits a while for a run already at work instead of skipping at
# once: on a fresh install racing a timer, the deploy would otherwise start
# the application before that run has created the current month. The wait
# is bounded by its own lock_timeout; past it, the run is skipped as a try
# would be. The month transactions' timeout is set again afterwards.
sub _wait_for_lock ( $self, $handle, $result ) {
    _execute(
        $handle,
        sprintf 'SET lock_timeout = %d',
        _milliseconds( $self->lock_wait_ms, 'lock_wait_ms' )
    );
    my $taken = eval {
        $handle->selectrow_array( $WAIT_LOCK_SQL, undef,
            $MAINTENANCE_LOCK_KEY );
        return 1;
    };
    my $failure = $EVAL_ERROR;
    $self->_apply_lock_timeout( $handle, $result );
    croak $failure if !$taken && $failure !~ $LOCK_TIMEOUT_PATTERN;
    $result->{locked} = $taken ? 1 : 0;

    return $result->{locked};
}

# Released on every path, or the connection would keep it: Migrate reuses
# its handle after the run.
sub _release_lock ( $handle, $result ) {
    return if !$result->{locked};

    my $released = eval {
        $handle->selectrow_array( $UNLOCK_SQL, undef, $MAINTENANCE_LOCK_KEY );
        return 1;
    };
    if ($released) {
        delete $result->{locked};
    }

    return;
}

# How far ahead each partitioned table has partitions, and whether rows have
# spilled into its DEFAULT partition: one catalog query and one EXISTS per
# table, cheap enough for every readiness probe.
sub horizon_report ( $self, $dbh, $now_epoch ) {
    my %horizon =
      map { $_->[0] => $_->[1] }
      @{ $dbh->selectall_arrayref( $HORIZON_SQL, undef, [@PARTITIONED_TABLES] )
      };

    return $self->evaluate_horizon(
        {
            now_epoch => $now_epoch,
            tables    => [
                map {
                    {
                        default_rows  => $self->_default_has_rows( $dbh, $_ ),
                        horizon_epoch => $horizon{$_},
                        table         => $_,
                    }
                } @PARTITIONED_TABLES
            ],
        }
    );
}

sub evaluate_horizon ( $self, $input ) {
    my %given = map { $_->{table} => $_ } @{ $input->{tables} || [] };
    my ( @problems, @tables );
    for my $table (@PARTITIONED_TABLES) {
        my $state   = $given{$table} || { table => $table };
        my $horizon = $state->{horizon_epoch};
        my $days =
          defined $horizon
          ? int( ( $horizon - $input->{now_epoch} ) / $SECONDS_PER_DAY )
          : undef;
        push @tables,
          {
            days_left    => $days,
            default_rows => $state->{default_rows} ? 1             : 0,
            horizon      => defined $horizon ? _iso_date($horizon) : undef,
            table        => $table,
          };
        push @problems, _horizon_problems( $self, $tables[-1] );
    }

    return {
        problems     => \@problems,
        status       => @problems ? 'degraded' : 'ok',
        tables       => \@tables,
        warning_days => $HORIZON_WARNING_DAYS,
    };
}

sub _horizon_problems ( $self, $state ) {
    my @problems;
    my $table = $state->{table};
    if ( !defined $state->{days_left} ) {
        push @problems, "$table has no range partition at all;"
          . ' run bin/gpforum-partition-maintenance --apply';
    }
    elsif ( $state->{days_left} < $HORIZON_WARNING_DAYS ) {
        push @problems,
            "$table has partitions only until $state->{horizon},"
          . " $state->{days_left} days away;"
          . ' run bin/gpforum-partition-maintenance --apply';
    }
    if ( $state->{default_rows} ) {
        push @problems,
            $self->default_partition_name($table)
          . ' holds rows, so the partition window fell behind;'
          . ' see docs/ops/partition-maintenance.md';
    }

    return @problems;
}

sub _default_has_rows ( $self, $dbh, $table ) {
    my $default = $self->default_partition_name($table);
    my ($exists) =
      $dbh->selectrow_array("SELECT EXISTS (SELECT 1 FROM ONLY $default)");

    return $exists ? 1 : 0;
}

sub _iso_date ($epoch) {
    return strftime( '%Y-%m-%d', gmtime $epoch );
}

sub next_state ( $, $state ) {
    if ( !$state || !exists $NEXT_STATE{$state} ) {
        return undef;
    }

    return $NEXT_STATE{$state};
}

sub retention_due ( $self, $input ) {
    my $cutoff = $self->_cutoff_iso($input);
    my @due;
    for my $row ( @{ $input->{partitions} || [] } ) {
        if ( $self->_is_retention_due( $row, $cutoff ) ) {
            push @due, $self->_recommendation($row);
        }
    }

    return \@due;
}

sub restore_evidence ( $self, $input ) {
    my $counts  = $self->_state_counts( $input->{partitions} || [] );
    my $created = $counts->{created} || 0;

    return {
        ok               => $created ? 1 : 0,
        partition_counts => $counts,
        policy_version   => $POLICY_VERSION,
        restore_ready    => $created ? 1 : 0,
        tables           => $self->partitioned_tables,
    };
}

sub _ensure_partition ( $self, $handle, $plan, $result ) {
    my $done = eval { return $self->_ensure_one( $handle, $plan, $result ); };
    if ( !$done ) {
        push @{ $result->{errors} },
          { %{ $self->_evidence($plan) }, error => _reason($EVAL_ERROR) };
    }

    return undef;
}

sub _ensure_one ( $self, $handle, $plan, $result ) {
    my $name =
      $self->validate_partition_name( $plan->{table_name},
        $plan->{partition_name} );
    if ( _relation_exists( $handle, $name ) ) {
        push @{ $result->{existing} }, $self->_evidence($plan);
        $self->_sync_registry( $handle, $plan, $result );
        return 1;
    }
    my $conflict = $self->_default_conflict( $handle, $plan );
    if ($conflict) {
        push @{ $result->{conflicts} }, $conflict;
        return 1;
    }
    $self->_create_partition( $handle, $plan, $result );

    return 1;
}

sub _create_partition ( $self, $handle, $plan, $result ) {
    my $statement = $self->create_statement($plan);
    if ( !$result->{applied} ) {
        push @{ $result->{planned} }, $self->_evidence( $plan, $statement );
        return undef;
    }
    my $failure = $self->_create_with_retries( $handle, $plan );
    if ( defined $failure ) {
        return $self->_record_failure( $plan, $failure, $result );
    }
    push @{ $result->{created} }, $self->_evidence( $plan, $statement );

    return;
}

# A lock timeout is retried after a pause, up to lock_attempts times in all;
# anything else, a DEFAULT overlap above all, is final at once. Returns the
# last failure, or undef once the month is in.
sub _create_with_retries ( $self, $handle, $plan ) {
    my $attempts = $self->lock_attempts;
    croak 'partition lifecycle: lock_attempts must be a positive integer'
      if !defined $attempts || $attempts !~ $POSITIVE_INTEGER_PATTERN;
    my @statements = (
        ( map { [$_] } @{ $self->create_statements($plan) } ),
        [ $REGISTRY_UPSERT, $self->_registry_values($plan) ]
    );
    my $pause =
      _milliseconds( $self->retry_pause_ms, 'retry_pause_ms' ) / $MILLISECONDS;
    my ( $failure, $state ) = _transaction( $handle, @statements );
    my $attempt = 1;
    while ( defined $failure
        && $attempt < $attempts
        && _is_lock_timeout( $failure, $state ) )
    {
        if ($pause) {
            Time::HiRes::sleep($pause);
        }
        ( $failure, $state ) = _transaction( $handle, @statements );
        $attempt += 1;
    }

    return $failure;
}

sub _is_lock_timeout ( $failure, $state ) {
    return 1 if ( $state // q{} ) eq $LOCK_TIMEOUT_STATE;

    return $failure =~ $LOCK_TIMEOUT_PATTERN ? 1 : 0;
}

# The new table, its attachment and its registry row commit together or not
# at all: a lock timeout or a DEFAULT overlap on the ATTACH leaves no
# unattached table behind to be mistaken next run for an existing partition.
# Only a transaction begun here is rolled back; one that could not begin --
# the handle already inside a caller's -- is the caller's to end. Returns
# undef, or the failure and its SQLSTATE, read before the rollback clears it.
sub _transaction ( $handle, @statements ) {
    my $begun = 0;
    my $done  = eval {
        $handle->begin_work;
        $begun = 1;
        for my $statement (@statements) {
            my ( $sql, @bind ) = @{$statement};
            _dispatch( $handle, $sql, \@bind );
        }
        $handle->commit;
        return 1;
    };
    return undef if $done;

    my $failure = _reason($EVAL_ERROR);
    my $state   = $handle->can('state') ? $handle->state : undef;
    if ($begun) {
        my $rolled_back = eval { $handle->rollback; return 1; };
        if ( !$rolled_back ) {
            $failure .= '; rollback failed: ' . _reason($EVAL_ERROR);
        }
    }

    return ( $failure, $state );
}

sub _record_failure ( $self, $plan, $failure, $result ) {
    if ( $failure =~ $DEFAULT_CONFLICT_PATTERN ) {
        push @{ $result->{conflicts} },
          $self->conflict_report( $plan, undef, $failure );
        return;
    }
    push @{ $result->{errors} },
      { %{ $self->_evidence($plan) }, error => $failure };

    return;
}

sub _default_conflict ( $self, $handle, $plan ) {
    my $default = $self->default_partition_name( $plan->{table_name} );
    if ( !_relation_exists( $handle, $default ) ) {
        return undef;
    }
    my $rows = $self->_default_rows( $handle, $default, $plan );
    if ( !$rows ) {
        return undef;
    }

    return $self->conflict_report( $plan, $rows );
}

sub _default_rows ( $self, $handle, $default, $plan ) {
    my $statement = sprintf $COUNT_TEMPLATE, $default, $PARTITION_KEY,
      $PARTITION_KEY;
    my $rows = eval {
        return scalar $handle->selectrow_array(
            $statement, undef,
            _bound_value( $plan->{range_start_sql} ),
            _bound_value( $plan->{range_end_sql} )
        );
    };
    croak 'partition lifecycle: default partition probe failed for '
      . $default . q{: }
      . _reason($EVAL_ERROR)
      if !defined $rows;

    return $rows;
}

sub _sync_registry ( $self, $handle, $plan, $result ) {
    if ( !$result->{applied} ) {
        return;
    }
    my $failure =
      _execute( $handle, $REGISTRY_UPSERT, $self->_registry_values($plan) );
    if ( defined $failure ) {
        push @{ $result->{errors} },
          { %{ $self->_evidence($plan) }, error => $failure };
    }

    return;
}

sub _registry_values ( $self, $plan ) {
    return (
        $self->validate_table_name( $plan->{table_name} ),
        $self->validate_partition_name(
            $plan->{table_name}, $plan->{partition_name}
        ),
        _bound_value( $plan->{range_start_sql} ),
        _bound_value( $plan->{range_end_sql} ),
        'created'
    );
}

sub _apply_lock_timeout ( $self, $handle, $result ) {
    if ( !$result->{applied} ) {
        return;
    }
    _execute(
        $handle,
        sprintf 'SET lock_timeout = %d',
        _milliseconds( $self->lock_timeout_ms, 'lock_timeout_ms' )
    );

    return;
}

# Unset, the session's own statement_timeout stands: the configured one on
# the timer's connection. migrate sets it, since it lifted the timeout for its
# migrations, and an ATTACH scans the whole DEFAULT partition while it holds
# that partition's ACCESS EXCLUSIVE.
sub _apply_statement_timeout ( $self, $handle, $result ) {
    my $milliseconds = $self->statement_timeout_ms;
    return if !$result->{applied} || !defined $milliseconds;

    _execute(
        $handle,
        sprintf 'SET statement_timeout = %d',
        _milliseconds( $milliseconds, 'statement_timeout_ms' )
    );

    return;
}

sub _milliseconds ( $value, $name ) {
    croak "partition lifecycle: $name must be a positive integer"
      if !defined $value || $value !~ /\A [[:digit:]]+ \z/msx;

    return $value;
}

sub _require_dbh ( $self, $input ) {
    my $handle = $input->{dbh} || $self->dbh || $self->_schema_dbh;
    croak 'partition lifecycle: a database handle is required'
      if !$handle;

    return $handle;
}

# The schema's connection, or why there is none. The connection error was
# swallowed here, so partition-maintenance against a database it could not
# reach said only "a database handle is required" -- true, and no help to an
# operator looking for a refused port or a rejected password. The reason is
# kept, on one line and without the code locations DBI and DBIx::Class append
# to it. It can quote the DSN, password= and all: the command printing it
# redacts it (GPForum::Command::Usage->failure).
sub _schema_dbh ($self) {
    my $schema = $self->schema;
    return undef if !$schema;

    my $handle = eval { return $schema->storage->dbh; };
    return $handle if $handle;

    my $reason = _reason($EVAL_ERROR);
    croak "partition lifecycle: cannot connect to the database: $reason"
      if length $reason;

    return undef;
}

sub _lookahead ( $self, $input ) {
    my $months =
         $input->{lookahead_months}
      || $input->{horizon_months}
      || $self->lookahead_months;
    croak 'partition lifecycle: lookahead_months must be a positive integer'
      if !defined $months
      || $months !~ $POSITIVE_INTEGER_PATTERN;

    return int $months;
}

sub _partition_of_statement ( $self, $plan ) {
    my $table = $self->validate_table_name( $plan->{table_name} );
    my $partition =
      $self->validate_partition_name( $table, $plan->{partition_name} );

    return sprintf $PARTITION_OF_TEMPLATE, $partition, $table,
      _bound_literal( $plan->{range_start_sql} ),
      _bound_literal( $plan->{range_end_sql} );
}

sub _range_predicate ( $self, $plan ) {
    $self->validate_table_name( $plan->{table_name} );

    return sprintf '%s >= %s AND %s < %s', $PARTITION_KEY,
      _bound_literal( $plan->{range_start_sql} ), $PARTITION_KEY,
      _bound_literal( $plan->{range_end_sql} );
}

sub _evidence ( $self, $plan, $statement = undef ) {
    my %evidence = (
        default_partition =>
          $self->default_partition_name( $plan->{table_name} ),
        partition_name => $plan->{partition_name},
        range_end      => $plan->{range_end},
        range_start    => $plan->{range_start},
        table_name     => $plan->{table_name},
    );
    if ( defined $statement ) {
        $evidence{create_sql} = $statement;
    }

    return \%evidence;
}

sub _plans_for_month ( $self, $month ) {
    my @plans;
    for my $table ( @{ $self->partitioned_tables } ) {
        push @plans, $self->_plan_row( $table, $month );
    }

    return @plans;
}

sub _plan_row ( $self, $table, $month ) {
    my $next = _shift_ym( $month, 1 );
    my %plan = (
        partition_name =>
          sprintf( '%s_%04d_%02d', $table, $month->{year}, $month->{month} ),
        range_end       => _iso_month_start($next),
        range_end_sql   => _sql_month_start($next),
        range_start     => _iso_month_start($month),
        range_start_sql => _sql_month_start($month),
        state           => 'planned',
        table_name      => $table,
    );
    $plan{create_sql} = $self->create_statement( \%plan );

    return \%plan;
}

sub _month_starts ( $, $epoch, $count ) {
    my $origin = _ym($epoch);
    my @starts;
    my $offset = 0;
    while ( $offset < $count ) {
        push @starts, _shift_ym( $origin, $offset );
        $offset += 1;
    }

    return @starts;
}

sub _cutoff_iso ( $, $input ) {
    my $days  = $input->{retention_days} || 0;
    my $epoch = ( $input->{now_epoch} || 0 ) - ( $days * $SECONDS_PER_DAY );

    return _iso_from_epoch($epoch);
}

sub _is_retention_due ( $, $row, $cutoff ) {
    if ( ( $row->{state} || q{} ) ne 'created' ) {
        return 0;
    }

    return ( $row->{range_end} || q{} ) le $cutoff ? 1 : 0;
}

sub _recommendation ( $self, $row ) {
    return { %{$row},
        recommended_state => $self->next_state( $row->{state} ), };
}

sub _state_counts ( $, $rows ) {
    my %counts = (
        archived => 0,
        created  => 0,
        detached => 0,
        dropped  => 0,
        planned  => 0,
    );
    for my $row ( @{$rows} ) {
        my $state = $row->{state} || 'planned';
        if ( exists $counts{$state} ) {
            $counts{$state} += 1;
        }
    }

    return \%counts;
}

sub _empty_result ( $lookahead, $apply ) {
    return {
        applied          => ( defined $apply && !$apply ) ? 0 : 1,
        conflicts        => [],
        created          => [],
        errors           => [],
        existing         => [],
        lookahead_months => $lookahead,
        ok               => 1,
        planned          => [],
        policy_version   => $POLICY_VERSION,
        skipped          => 0,
    };
}

sub _relation_exists ( $handle, $name ) {
    my $found = eval {
        return
          scalar $handle->selectrow_array( 'SELECT to_regclass(?)',
            undef, $name );
    };

    return $found ? 1 : 0;
}

sub _execute ( $handle, $statement, @bind ) {
    my $done = eval { return _dispatch( $handle, $statement, \@bind ); };
    if ($done) {
        return undef;
    }

    return _reason($EVAL_ERROR);
}

sub _dispatch ( $handle, $statement, $bind ) {
    if ( $handle->can('execute_statement') ) {
        $handle->execute_statement( $statement, undef, @{$bind} );
        return 1;
    }
    $handle->do( $statement, undef, @{$bind} );

    return 1;
}

sub _conflict_message ($report) {
    return sprintf
      'rows already in %s overlap %s [%s, %s); move them before attaching',
      $report->{default_partition}, $report->{partition_name},
      $report->{range_start},       $report->{range_end};
}

sub _bound_literal ($value) {
    return sprintf q{TIMESTAMPTZ '%s'}, _bound_value($value);
}

sub _bound_value ($value) {
    my $bound = defined $value ? $value : q{};
    croak "partition lifecycle: unsafe range bound '$bound'"
      if $bound !~ $BOUND_PATTERN;

    return $bound;
}

sub _trim ($message) {
    my $text = defined $message ? "$message" : q{};
    $text =~ s/\s+/ /gmsx;
    $text =~ s/\A\s+|\s+\z//gmsx;

    return $text;
}

# A rethrown error carries one " at FILE line N." per throw -- DBI's, then
# DBIx::Class's -- and every trailing one goes.
sub _reason ($error) {
    my $text = _trim($error);
    while ( $text =~ s/\s+ at \s+ \S+ \s+ line \s+ [[:digit:]]+ [.]? \z//msx ) {
    }

    return $text;
}

sub _ym ($epoch) {
    my ( undef, undef, undef, undef, $month, $year ) = gmtime $epoch;

    return {
        month => $month + 1,
        year  => $year + $EPOCH_YEAR_OFFSET,
    };
}

sub _shift_ym ( $origin, $delta ) {
    my $index =
      ( $origin->{year} * $MONTHS_PER_YEAR ) +
      ( $origin->{month} - 1 ) +
      $delta;

    return {
        month => ( $index % $MONTHS_PER_YEAR ) + 1,
        year  => int( $index / $MONTHS_PER_YEAR ),
    };
}

sub _iso_month_start ($ym) {
    return sprintf '%04d-%02d-01T00:00:00Z', $ym->{year}, $ym->{month};
}

sub _sql_month_start ($ym) {
    return sprintf '%04d-%02d-01 00:00:00+00', $ym->{year}, $ym->{month};
}

sub _iso_from_epoch ($epoch) {
    my ( $sec, $minute, $hour, $day, $month, $year ) = gmtime $epoch;

    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
      $year + $EPOCH_YEAR_OFFSET,
      $month + 1, $day, $hour, $minute, $sec;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::PartitionLifecycle - Partition lifecycle policy
and monthly partition DDL.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $lifecycle = GPForum::Service::Operations::PartitionLifecycle->new;

    my $plans = $lifecycle->plan_window(
        { now_epoch => time, horizon_months => 3 } );

    my $result = $lifecycle->ensure_partitions(
        { dbh => $dbh, lookahead_months => 3 } );

    my $horizon = $lifecycle->horizon_report( $dbh, time );

=head1 DESCRIPTION

Owns the operational lifecycle of the range-partitioned C<event_log>,
C<audit_log>, and C<notifications> tables. All three are declared
C<PARTITION BY RANGE (created_at)> with a DEFAULT partition
(C<event_log_default>, C<audit_log_default>, C<notifications_default>).

The boundary plans monthly windows, creates the corresponding range partitions
ahead of time, records them in C<partition_registry>, recommends retention
transitions, and emits restore evidence. For readiness it reports how far
ahead each table has partitions and whether rows have spilled into a DEFAULT
partition.

Month boundaries are computed in UTC with C<gmtime>. Every emitted bound is an
explicit C<TIMESTAMPTZ 'YYYY-MM-DD 00:00:00+00'> literal so the DDL does not
depend on the session C<TimeZone>.

=head2 Identifier safety

PostgreSQL cannot bind identifiers, so C<CREATE TABLE> and C<ATTACH PARTITION>
have to interpolate table and partition names. Every identifier is therefore
built from the module's own table allowlist plus a derived C<YYYY_MM> suffix,
and is validated twice before it reaches SQL: once against
C<qr/\A[a-z][a-z0-9_]{2,61}\z/> and once against the allowlist or the
C<< <table>_<year>_<month> >> shape. Range bounds are validated against a
fixed C<YYYY-MM-DD HH:MM:SS+00> pattern. Anything else croaks. Values that can
be bound (registry columns, default-partition probes) are always bound.

=head2 Creating a month without a maintenance window

Each missing month is created in its own transaction, under a short
C<lock_timeout> (C<lock_timeout_ms>, half a second; see L</Attributes>):

    BEGIN;
    CREATE TABLE notifications_2026_11 (LIKE notifications
        INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING STORAGE
        INCLUDING COMMENTS INCLUDING COMPRESSION INCLUDING GENERATED);
    ALTER TABLE notifications ATTACH PARTITION notifications_2026_11
        FOR VALUES FROM (TIMESTAMPTZ '2026-11-01 00:00:00+00')
        TO (TIMESTAMPTZ '2026-12-01 00:00:00+00');
    INSERT INTO partition_registry ... ON CONFLICT ... DO UPDATE ...;
    COMMIT;

C<ATTACH PARTITION> takes SHARE UPDATE EXCLUSIVE on the parent, which no read
or write conflicts with, where C<CREATE TABLE ... PARTITION OF> took ACCESS
EXCLUSIVE and so waited behind, and blocked, every transaction on the table.
ACCESS EXCLUSIVE falls on the new table and on the DEFAULT partition, and
SHARE ROW EXCLUSIVE on C<users> while C<notifications>' foreign key is
cloned, all until the commit. The attach builds the parent's partitioned
indexes on the new table and attaches them, with the names C<PARTITION OF>
gives them, and clones the primary key and foreign keys; the partition ends
up as C<PARTITION OF> would have made it.

What still waits is everything that opens the DEFAULT partition: any read the
planner cannot prune to one month -- a lookup by C<event_id> or
C<idempotency_key>, the audit chain tip, a filter on C<now()> -- and so the
application's event and audit writes, which start with such a read, and
writes to C<users> during a C<notifications> attach. A plain C<INSERT>
routed to its month, and a read pruned at plan time, go past. They wait while
the ATTACH waits for DEFAULT, behind any open transaction that read it, and
while the ATTACH holds it, which is as long as the scan of DEFAULT takes. So
the wait is cut short (half a second), and a month whose lock is not granted
in time is tried again, after a pause in which the queue drains, up to
C<lock_attempts> times; each stall is then at most C<lock_timeout_ms> plus
that scan. F<t/integration/postgres-partition-maintenance.t> holds all of
this to PostgreSQL.

A run first takes the session-level advisory lock L</maintenance_lock_key>
with C<pg_try_advisory_lock>, or, when C<lock_wait_ms> is set, waits that
long for it with C<pg_advisory_lock>. A run that does not get it -- another
node's timer, or a deploy's migrate, is already at it -- writes nothing and
returns with C<skipped> set and C<ok> true.

=head2 The DEFAULT partition trap

A DEFAULT partition holds every row that no range partition accepts. Attaching
a new range partition makes PostgreSQL take an ACCESS EXCLUSIVE lock on the
default partition and scan it; if a single row in the default partition falls
inside the new range, PostgreSQL aborts with C<updated partition constraint
for default partition ... would be violated by some row>, and the
transaction takes the new table with it.

C<ensure_partitions> probes the default partition for overlapping rows
B<before> issuing DDL and reports an actionable C<default_partition_overlap>
conflict instead of an opaque PostgreSQL error. A conflict raised by
PostgreSQL itself (a row written between the probe and the DDL) is classified
the same way.

Operators resolve a conflict by hand, during a maintenance window, with the
statements returned in C<remediation> (also available from
L</remediation_steps>):

    BEGIN;
    ALTER TABLE event_log DETACH PARTITION event_log_default;
    CREATE TABLE IF NOT EXISTS event_log_2026_09 PARTITION OF event_log
        FOR VALUES FROM (TIMESTAMPTZ '2026-09-01 00:00:00+00')
        TO (TIMESTAMPTZ '2026-10-01 00:00:00+00');
    INSERT INTO event_log SELECT * FROM event_log_default
        WHERE created_at >= TIMESTAMPTZ '2026-09-01 00:00:00+00'
          AND created_at < TIMESTAMPTZ '2026-10-01 00:00:00+00';
    DELETE FROM event_log_default
        WHERE created_at >= TIMESTAMPTZ '2026-09-01 00:00:00+00'
          AND created_at < TIMESTAMPTZ '2026-10-01 00:00:00+00';
    ALTER TABLE event_log ATTACH PARTITION event_log_default DEFAULT;
    COMMIT;

The transaction takes ACCESS EXCLUSIVE locks on the parent and the default
partition: writers block for its duration, so it belongs in a maintenance
window and not in the scheduled run. Keeping the lookahead ahead of traffic is
what stops this from ever being needed.

=head1 SUBROUTINES/METHODS

=head2 Attributes

C<dbh> and C<schema> give the connection (C<dbh> first). C<lookahead_months>
(3) is the default window. C<lock_timeout_ms> (500) bounds each lock wait of
a month's transaction, and a month timed out on a lock is tried
C<lock_attempts> (5) times in all, C<retry_pause_ms> (1000) apart.
C<lock_wait_ms> (0) is how long to wait for the maintenance lock, 0 to only
try it. C<statement_timeout_ms>, when set, is applied to the session before
an applying run; unset, the session's own stands.

=head2 partitioned_tables

Returns the tables covered by this policy.

=head2 policy_version

Returns the lifecycle policy version.

=head2 partition_key

Returns the range partition key column (C<created_at>) for a validated table.

=head2 validate_table_name

Returns the table name when it is one of the partitioned tables and matches the
strict identifier pattern. Croaks otherwise.

=head2 validate_partition_name

Returns the partition name when it matches the strict identifier pattern and is
a C<< <table>_<year>_<month> >> child of the given table. Croaks otherwise.

=head2 default_partition_name

Returns the DEFAULT partition name for a validated table.

=head2 plan_window

Plans monthly partitions from the current month through the requested horizon.
Takes a hash reference with C<now_epoch>, whose UTC month comes first, and
C<horizon_months> (default 1); without C<now_epoch> the plan starts at
January 1970. Returns an array reference with one plan row per table and
month. Each plan row carries C<table_name>, C<partition_name>, C<state>
(C<planned>) and the UTC window in both ISO-8601 (C<range_start>,
C<range_end>) and SQL literal (C<range_start_sql>, C<range_end_sql>) form, plus
the C<create_sql> that would be executed.

=head2 maintenance_lock_key

The key of the session-level advisory lock a maintenance run holds,
4021970002, next to the migration runner's 4021970001. Exposed so a test or
an operator's C<pg_locks> query can name it.

=head2 create_statements

Returns, for a plan row, the two statements run in one transaction: the
C<CREATE TABLE ... (LIKE ...)> and the C<ALTER TABLE ... ATTACH PARTITION ...
FOR VALUES FROM ... TO ...>.

=head2 create_statement

Returns L</create_statements> joined by C<; >, the C<create_sql> a plan row
and the evidence carry.

=head2 remediation_steps

Returns the ordered statements an operator runs by hand to clear a
default-partition overlap.

=head2 conflict_report

Builds the actionable C<default_partition_overlap> report for a plan row.
Takes the plan row, the number of overlapping rows (undef when unknown,
reported as -1) and an optional detail, PostgreSQL's own message. Returns a
hash reference with C<table_name>, C<partition_name>, C<default_partition>,
C<range_start>, C<range_end>, C<conflicting_rows>, C<error>, C<message>,
C<remediation> (from L</remediation_steps>) and, when given, C<detail>.

=head2 ensure_partitions

Creates every missing partition in the lookahead window and upserts
C<partition_registry>. Accepts C<dbh>, C<now_epoch>, C<lookahead_months>, and
C<apply>; with C<< apply => 0 >> nothing is written and the missing partitions
are returned under C<planned>. Returns C<ok>, C<created>, C<existing>,
C<planned>, C<conflicts>, and C<errors>.

C<horizon_months> is accepted in place of C<lookahead_months>, and both
default to the C<lookahead_months> attribute; C<now_epoch> defaults to the
current time. A partition that already exists is listed under C<existing>
and its registry row upserted too. The result also carries C<applied>,
C<lookahead_months>, C<policy_version> and C<skipped>; C<ok> is 0 when there
is any conflict or error. Before writing, the session's C<lock_timeout> is
set to C<lock_timeout_ms>, its C<statement_timeout> to C<statement_timeout_ms>
when that is set, and the advisory lock is taken as L</Attributes> says;
without it the result has C<skipped> 1, C<ok> 1 and empty lists. Each created
partition, its attachment and its registry row commit together, or roll back
together; a lock timeout is retried, and what is left is reported under
C<conflicts> or C<errors>, without the code locations DBI appends.

=head2 horizon_report

Takes a database handle and the current epoch. Reads, in one catalog query,
the latest upper bound among each table's range partitions, and asks of each
table's DEFAULT partition whether it holds any row. Returns the result of
L</evaluate_horizon> for those facts. Database errors propagate.

=head2 evaluate_horizon

Takes a hash reference with C<now_epoch> and C<tables>, an array reference
of C<< { table, horizon_epoch, default_rows } >>; a partitioned table
missing from it is judged as having no range partition. Returns
C<< { status, problems, tables, warning_days } >>: C<tables> holds, for
each partitioned table, C<days_left> and C<horizon> (a C<YYYY-MM-DD> date;
both undef when there is no range partition) and C<default_rows> (0 or 1);
C<problems> is a list of operator messages, one for a table with no range
partition or fewer than C<warning_days> (45) days left, and one for a
DEFAULT partition holding rows; C<status> is C<degraded> when there is any
problem, C<ok> otherwise.

=head2 next_state

Returns the next registry state for C<planned>, C<created>, C<detached>, or
C<archived> (C<created>, C<detached>, C<archived>, C<dropped>), and undef for
any other state.

=head2 retention_due

Returns created partitions whose range has aged past the retention cutoff, with
a recommended C<detached> state. Takes a hash reference with C<now_epoch>,
C<retention_days> and C<partitions>, the registry rows as hash references
with at least C<state> and C<range_end>. A row is due when its C<state> is
C<created> and its C<range_end> is not after the cutoff, C<now_epoch> less
C<retention_days>; the comparison is on the text, against a
C<YYYY-MM-DDTHH:MM:SSZ> cutoff. Returns an array reference of copies of the
due rows with C<recommended_state>.

=head2 restore_evidence

Summarizes registry rows for restore and archival evidence. Takes a hash
reference with C<partitions>, the registry rows. Returns
C<< { ok, restore_ready, partition_counts, policy_version, tables } >>:
C<partition_counts> counts the rows per state (a row without one counts as
C<planned>), and C<ok> and C<restore_ready> are 1 when at least one
partition is C<created>.

=head1 DIAGNOSTICS

=over 4

=item C<partition lifecycle: unsafe table identifier '...'>

The table name failed the identifier pattern.

=item C<partition lifecycle: '...' is not a partitioned table>

The table is not one of C<audit_log>, C<event_log>, C<notifications>.

=item C<partition lifecycle: unsafe partition identifier '...'>

=item C<partition lifecycle: '...' is not a month partition of '...'>

The partition name is not a C<< <table>_<year>_<month> >> child.

=item C<partition lifecycle: unsafe range bound '...'>

A range bound is not a C<YYYY-MM-DD HH:MM:SS+00> literal.

=item C<partition lifecycle: a database handle is required>

C<ensure_partitions> was called without C<dbh>, C<< $self->dbh >>, or a schema.

=item C<partition lifecycle: cannot connect to the database: ...>

There is a schema but no connection to be had from it; the rest is the
connection error, on one line and without its code locations. It can quote
the DSN, an inline C<password=> included, so a caller that prints it redacts
it, as L<GPForum::Command::Usage/failure> does.

=item C<partition lifecycle: lookahead_months must be a positive integer>

The lookahead given to C<ensure_partitions> is not a whole number from 1 to
999.

=item C<partition lifecycle: lock_timeout_ms must be a positive integer>

=item C<partition lifecycle: lock_wait_ms must be a positive integer>

=item C<partition lifecycle: statement_timeout_ms must be a positive integer>

=item C<partition lifecycle: retry_pause_ms must be a positive integer>

The attribute is not made of digits; checked only when applying.

=item C<partition lifecycle: lock_attempts must be a positive integer>

C<lock_attempts> is not a whole number from 1 to 999; checked when a month
is created.

=item C<partition lifecycle: default partition probe failed for ...>

The overlap probe could not be run; the partition is left untouched.

=back

Everything C<ensure_partitions> raises per partition, including that probe
failure, is caught and returned in C<conflicts> or C<errors>, so one bad table
does not stop the maintenance run. Only the whole-run problems above
(missing handle, unreachable database, lookahead, lock timeout, and a
failure to ask for the advisory lock) propagate, as do the validation errors
raised by the public methods called directly. The advisory lock is released
before anything propagates.

=head1 CONFIGURATION AND ENVIRONMENT

Horizon months and retention days are arguments; the scheduled jobs take them
from L<GPForum::Service::Operations::Profile>. C<lookahead_months> defaults to
three months and C<lock_timeout_ms> to half a second, so a run gives up
instead of queueing behind live traffic: the parent's SHARE UPDATE EXCLUSIVE
waits for no read or write, but the DEFAULT partition's ACCESS EXCLUSIVE
waits for any transaction that read it, and every unpruned read, event and
audit writes with them, queues behind that request until it is granted or
times out. A month is then tried again, C<lock_attempts> times in all.

=head1 DEPENDENCIES

Uses L<Carp>, L<Const::Fast>, L<English>, L<POSIX>, L<Time::HiRes>, and
L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Detach, archive, and drop stay operator-owned (ADR 0113): this boundary
creates partitions and records state, and only recommends the retention
transitions.
Clearing a default-partition overlap is also manual, because it needs an
ACCESS EXCLUSIVE maintenance window. A failure to set C<lock_timeout> or
C<statement_timeout> is not reported; the run goes on with the session's own.
Each attach scans the whole DEFAULT partition under its ACCESS EXCLUSIVE, so
a DEFAULT holding history makes every attach as slow as that scan; moving
the history into range partitions (L</remediation_steps>) keeps it empty.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
