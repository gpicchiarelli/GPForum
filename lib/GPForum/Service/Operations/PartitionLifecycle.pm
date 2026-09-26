# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::PartitionLifecycle;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use POSIX   qw(strftime);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $EPOCH_YEAR_OFFSET    => 1900;
const my $MONTHS_PER_YEAR      => 12;
const my $POLICY_VERSION       => 1;
const my $SECONDS_PER_DAY      => 86_400;
const my $DEFAULT_LOOKAHEAD    => 3;
const my $DEFAULT_LOCK_TIMEOUT => 5_000;
const my $DEFAULT_SUFFIX       => '_default';
const my $PARTITION_KEY        => 'created_at';

# Monthly maintenance keeps three months ahead, so a horizon under 45 days
# means at least one monthly run was missed. Degraded, not failed: writes
# still land, in the DEFAULT partition, and the fix is an operator's.
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
const my $CREATE_TEMPLATE => join q{ },
  'CREATE TABLE IF NOT EXISTS %s', 'PARTITION OF %s',
  'FOR VALUES FROM (%s) TO (%s)';
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

has dbh              => undef;
has lock_timeout_ms  => sub { return $DEFAULT_LOCK_TIMEOUT; };
has lookahead_months => sub { return $DEFAULT_LOOKAHEAD; };
has schema           => undef;

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

sub create_statement ( $self, $plan ) {
    my $table = $self->validate_table_name( $plan->{table_name} );
    my $partition =
      $self->validate_partition_name( $table, $plan->{partition_name} );

    return sprintf $CREATE_TEMPLATE, $partition, $table,
      _bound_literal( $plan->{range_start_sql} ),
      _bound_literal( $plan->{range_end_sql} );
}

sub remediation_steps ( $self, $plan ) {
    my $table   = $self->validate_table_name( $plan->{table_name} );
    my $default = $self->default_partition_name($table);
    my $range   = $self->_range_predicate($plan);

    return [
        'BEGIN;',
        sprintf( 'ALTER TABLE %s DETACH PARTITION %s;', $table, $default ),
        $self->create_statement($plan) . q{;},
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
    for my $plan ( @{$plans} ) {
        $self->_ensure_partition( $handle, $plan, $result );
    }
    $result->{ok} =
      ( @{ $result->{conflicts} } || @{ $result->{errors} } ) ? 0 : 1;

    return $result;
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
          . ' holds rows, so a monthly run was missed;'
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
        my $undefined;
        return $undefined;
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
          { %{ $self->_evidence($plan) }, error => _trim($EVAL_ERROR) };
    }

    my $undefined;
    return $undefined;
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
        my $undefined;
        return $undefined;
    }
    my $failure = _execute( $handle, $statement );
    if ( defined $failure ) {
        return $self->_record_failure( $plan, $failure, $result );
    }
    push @{ $result->{created} }, $self->_evidence( $plan, $statement );

    return $self->_sync_registry( $handle, $plan, $result );
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
    my $undefined;

    my $default = $self->default_partition_name( $plan->{table_name} );
    if ( !_relation_exists( $handle, $default ) ) {
        return $undefined;
    }
    my $rows = $self->_default_rows( $handle, $default, $plan );
    if ( !$rows ) {
        return $undefined;
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
      . _trim($EVAL_ERROR)
      if !defined $rows;

    return $rows;
}

sub _sync_registry ( $self, $handle, $plan, $result ) {
    if ( !$result->{applied} ) {
        return;
    }
    my $failure = _execute(
        $handle,
        $REGISTRY_UPSERT,
        $self->validate_table_name( $plan->{table_name} ),
        $self->validate_partition_name(
            $plan->{table_name}, $plan->{partition_name}
        ),
        _bound_value( $plan->{range_start_sql} ),
        _bound_value( $plan->{range_end_sql} ),
        'created'
    );
    if ( defined $failure ) {
        push @{ $result->{errors} },
          { %{ $self->_evidence($plan) }, error => $failure };
    }

    return;
}

sub _apply_lock_timeout ( $self, $handle, $result ) {
    if ( !$result->{applied} ) {
        return;
    }
    my $milliseconds = $self->lock_timeout_ms;
    croak 'partition lifecycle: lock_timeout_ms must be a positive integer'
      if !defined $milliseconds
      || $milliseconds !~ /\A [0-9]+ \z/msx;
    _execute( $handle, sprintf 'SET lock_timeout = %d', $milliseconds );

    return;
}

sub _require_dbh ( $self, $input ) {
    my $handle = $input->{dbh} || $self->dbh || $self->_schema_dbh;
    croak 'partition lifecycle: a database handle is required'
      if !$handle;

    return $handle;
}

sub _schema_dbh ($self) {
    my $schema = $self->schema;
    if ( !$schema ) {
        my $undefined;
        return $undefined;
    }

    return eval { return $schema->storage->dbh; };
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
        my $undefined;
        return $undefined;
    }

    return _trim($EVAL_ERROR);
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

    my $plans = $lifecycle->plan_window(
        { now_epoch => time, horizon_months => 3 } );

    my $result = $lifecycle->ensure_partitions(
        { dbh => $dbh, lookahead_months => 3 } );

=head1 DESCRIPTION

Owns the operational lifecycle of the range-partitioned C<event_log>,
C<audit_log>, and C<notifications> tables. All three are declared
C<PARTITION BY RANGE (created_at)> with a DEFAULT partition
(C<event_log_default>, C<audit_log_default>, C<notifications_default>).

The boundary plans monthly windows, creates the corresponding range partitions
ahead of time, records them in C<partition_registry>, recommends retention
transitions, and emits restore evidence.

Month boundaries are computed in UTC with C<gmtime>. Every emitted bound is an
explicit C<TIMESTAMPTZ 'YYYY-MM-DD 00:00:00+00'> literal so the DDL does not
depend on the session C<TimeZone>.

=head2 Identifier safety

PostgreSQL cannot bind identifiers, so C<CREATE TABLE ... PARTITION OF> has to
interpolate table and partition names. Every identifier is therefore built from
the module's own table allowlist plus a derived C<YYYY_MM> suffix, and is
validated twice before it reaches SQL: once against
C<qr/\A[a-z][a-z0-9_]{2,61}\z/> and once against the allowlist or the
C<< <table>_<year>_<month> >> shape. Range bounds are validated against a
fixed C<YYYY-MM-DD HH:MM:SS+00> pattern. Anything else croaks. Values that can
be bound (registry columns, default-partition probes) are always bound.

=head2 The DEFAULT partition trap

A DEFAULT partition holds every row that no range partition accepts. Attaching
a new range partition makes PostgreSQL take an ACCESS EXCLUSIVE lock and scan
the default partition; if a single row in the default partition falls inside
the new range, PostgreSQL aborts with C<updated partition constraint for
default partition ... would be violated by some row>.

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
Each plan row carries the UTC window in both ISO-8601 (C<range_start>,
C<range_end>) and SQL literal (C<range_start_sql>, C<range_end_sql>) form, plus
the C<create_sql> that would be executed.

=head2 create_statement

Returns the idempotent C<CREATE TABLE IF NOT EXISTS ... PARTITION OF ... FOR
VALUES FROM ... TO ...> statement for a plan row.

=head2 remediation_steps

Returns the ordered statements an operator runs by hand to clear a
default-partition overlap.

=head2 conflict_report

Builds the actionable C<default_partition_overlap> report for a plan row.

=head2 ensure_partitions

Creates every missing partition in the lookahead window and upserts
C<partition_registry>. Accepts C<dbh>, C<now_epoch>, C<lookahead_months>, and
C<apply>; with C<< apply => 0 >> nothing is written and the missing partitions
are returned under C<planned>. Returns C<ok>, C<created>, C<existing>,
C<planned>, C<conflicts>, and C<errors>.

=head2 next_state

Returns the next registry state for C<planned>, C<created>, C<detached>, or
C<archived>.

=head2 retention_due

Returns created partitions whose range has aged past the retention cutoff, with
a recommended C<detached> state.

=head2 restore_evidence

Summarizes registry rows for restore and archival evidence.

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

=item C<partition lifecycle: default partition probe failed for ...>

The overlap probe could not be run; the partition is left untouched.

=back

Everything C<ensure_partitions> raises per partition, including that probe
failure, is caught and returned in C<conflicts> or C<errors>, so one bad table
does not stop the maintenance run. Only the whole-run problems above
(validation, missing handle) propagate.

=head1 CONFIGURATION AND ENVIRONMENT

Horizon and retention days come from L<GPForum::Service::Operations::Profile>.
C<lookahead_months> defaults to three months and C<lock_timeout_ms> to five
seconds, so a scheduled run gives up instead of queueing behind live traffic
while holding an ACCESS EXCLUSIVE lock request.

=head1 DEPENDENCIES

Uses L<Carp>, L<Const::Fast>, L<English>, and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Detach, archive, and drop stay operator-owned: this boundary creates
partitions and records state, and only recommends the retention transitions.
Clearing a default-partition overlap is also manual, because it needs an
ACCESS EXCLUSIVE maintenance window.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
