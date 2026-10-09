# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::StagingDrill;

use Carp qw(croak);
use Const::Fast;
use DBI;
use English    qw(-no_match_vars);
use File::Temp qw(tempfile);
use GPForum::X::Argument;
use GPForum::X::Config;
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Config;
use GPForum::Infrastructure::Storage;
use GPForum::Migration::Plan;
use GPForum::Migration::Runner;
use GPForum::Schema;
use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);
use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Service::Operations::StagingDrill::PgTools;
use GPForum::X::Check;

our $VERSION = '0.001';

const my $ATTACHMENTS_ROOT   => 'var/attachments';
const my $EXIT_FAILURE       => 1;
const my $PREVIOUS_INDEX_GAP => 1;
const my @SANITY_TABLES      => qw(schema_versions users threads);
const my @PHASES             => qw(fresh_migrate upgrade_path dump_restore);
const my @HUMAN_FIELDS =>
  qw(schema_versions schema_versions_after users threads);
const my %PHASE_OK => map { $_ => 1 } qw(pass skipped);
const my $ATTACHMENTS_LIMITATION =>
'pg_dump/pg_restore covers PostgreSQL only. Attachment blobs under var/attachments (FilesystemStorage) are not dumped or restored by this drill. Rehearse populated var/attachments blob restore with script/staging-drill-attachments; back up live operator trees separately.';
const my $RESIDUAL_DEPLOY_GAP =>
'Live Hypnotoad/TLS host bring-up remains manual; run script/staging-drill-attachments for nginx/systemd template checks (static plus host verify/-t when tools exist) and populated var/attachments restore.';
const my $RESIDUAL_BETA_GAP =>
  'This drill does not claim private-beta readiness.';
const my $PG_TOOLS => 'GPForum::Service::Operations::StagingDrill::PgTools';

has admin_dsn => undef;    # optional: from GPFORUM_DATABASE_DSN

# The seed step. The performance seed is a command, a layer above this
# service, so the command that builds the drill hands it in rather than the
# service reaching up for it. Called with the profile name; returns an exit
# status.
has seed    => undef;               # optional: needed only for a seed profile
has created => sub { return [] };
has tools   => undef;               # optional: PgTools, found on first use

sub run ( $self, $options ) {
    my $evidence = {
        check        => 'staging_drill',
        status       => undef,
        seed_profile => $options->{seed_profile},
        attachments  => {
            covered         => \0,
            storage_backend => 'filesystem',
            storage_root    => $ATTACHMENTS_ROOT,
            limitation      => $ATTACHMENTS_LIMITATION,
        },
        residual_gaps => [ $RESIDUAL_DEPLOY_GAP, $RESIDUAL_BETA_GAP ],
    };
    try {
        $self->_execute( $evidence, $options );
    }
    catch ($error) {
        $evidence->{status} = 'fail';
        $evidence->{error}  = _trim_error($error);
    };
    $self->_cleanup( $evidence, $options );
    $evidence->{status} ||= _status_from_phases($evidence);

    return evidence_finalize($evidence);
}

sub format_evidence ( $self, $evidence, $format ) {
    return encode_json($evidence) . "\n" if $format eq 'json';

    return _human_evidence($evidence);
}

sub exit_status ( $self, $evidence ) {
    return 0 if ( $evidence->{status} // q{} ) eq 'pass';

    return $EXIT_FAILURE;
}

sub rewrite_dsn ( $self, $dsn, $dbname ) {
    return $PG_TOOLS->rewrite_dsn( $dsn, $dbname );
}

sub parse_dsn ( $self, $dsn ) {
    return $PG_TOOLS->parse_dsn($dsn);
}

sub _execute ( $self, $evidence, $options ) {
    $self->_require_database_env;
    if ( !$options->{skip_dump_restore} ) {
        $self->tools( $PG_TOOLS->find );
    }
    $self->_run_fresh_phase( $evidence, $options );
    $self->_run_upgrade_phase( $evidence, $options );
    $self->_run_dump_restore_phase( $evidence, $options );

    return;
}

# Migrating twice must leave schema_versions as the first run left it.
sub _run_fresh_phase ( $self, $evidence, $options ) {
    my $database = $self->_create_throwaway( $options, 'fresh' );
    local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
    _apply_migrations();
    my $counts = _row_counts( $database->{dbh} );
    _apply_migrations();
    if ( _schema_version_count( $database->{dbh} ) !=
        $counts->{schema_versions} )
    {
        GPForum::X::Check->throw(
            message => 'second migrate changed schema_versions' );
    }
    _assert_full_schema( $counts->{schema_versions} );
    $evidence->{fresh_migrate} = {
        status              => 'pass',
        database            => $database->{name},
        schema_versions     => $counts->{schema_versions},
        expected_migrations => _migration_count(),
        second_apply_delta  => 0,
    };
    $evidence->{_fresh} = $database;

    return;
}

# A database migrated to the version before the latest, then to the latest.
sub _run_upgrade_phase ( $self, $evidence, $options ) {
    my $skipped = _upgrade_skip_reason($options);
    if ($skipped) {
        $evidence->{upgrade_path} = $skipped;
        return;
    }

    my $plan         = GPForum::Migration::Plan->new->summary;
    my $latest_index = $#{$plan};
    my $previous     = $plan->[ $latest_index - $PREVIOUS_INDEX_GAP ]{version};
    my $latest       = $plan->[$latest_index]{version};
    my $database     = $self->_create_throwaway( $options, 'upgrade' );
    local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
    _apply_through_version( $database, $previous );
    my $before = _schema_version_count( $database->{dbh} );
    _apply_migrations();
    my $after = _schema_version_count( $database->{dbh} );
    _assert_full_schema($after);
    $evidence->{upgrade_path} = {
        status                 => 'pass',
        database               => $database->{name},
        from_version           => $previous,
        to_version             => $latest,
        schema_versions_before => $before,
        schema_versions_after  => $after,
        expected_migrations    => _migration_count(),
    };

    return;
}

sub _upgrade_skip_reason ($options) {
    if ( $options->{skip_upgrade} ) {
        return {
            status => 'skipped',
            reason => 'operator passed --skip-upgrade',
        };
    }

    my $plan = GPForum::Migration::Plan->new->summary;
    if ( @{$plan} < 2 ) {
        return {
            status => 'skipped',
            reason => 'fewer than two migrations; upgrade path not feasible',
        };
    }

    return undef;
}

# The fresh database, seeded, dumped and restored into another: the sanity
# tables must count the same rows in both.
sub _run_dump_restore_phase ( $self, $evidence, $options ) {
    if ( $options->{skip_dump_restore} ) {
        $evidence->{dump_restore} = {
            status => 'skipped',
            reason => 'operator passed --skip-dump-restore',
        };
        return;
    }

    my $source = $evidence->{_fresh};
    if ( !$source ) {
        GPForum::X::Check->throw( message =>
              'dump/restore requires a successful fresh migrate phase' );
    }
    local $ENV{GPFORUM_DATABASE_DSN} = $source->{dsn};
    $self->_seed_if_requested($options);
    my $before = _row_counts( $source->{dbh} );
    my ( $handle, $dump ) =
      tempfile( 'gpforum-drill-XXXXXX', SUFFIX => '.dump' );
    close $handle or croak 'failed to close temporary dump handle';
    $self->tools->dump_database( $source->{dsn}, $dump );
    my $target = $self->_create_throwaway( $options, 'restore' );
    $self->tools->restore_database( $target->{dsn}, $dump );
    unlink $dump;
    my $after = _row_counts( $target->{dbh} );

    for my $table (@SANITY_TABLES) {
        if ( $before->{$table} != $after->{$table} ) {
            GPForum::X::Check->throw( message =>
"restore mismatch on $table: $before->{$table} vs $after->{$table}"
            );
        }
    }
    $evidence->{dump_restore} = {
        status           => 'pass',
        source_database  => $source->{name},
        restore_database => $target->{name},
        schema_versions  => $after->{schema_versions},
        users            => $after->{users},
        threads          => $after->{threads},
    };

    return;
}

# What migrate --apply does: every pending migration, in order, with the
# statement timeout lifted for long DDL, then the partition window from the
# current month (ADR 0113), so the seeded database writes into month
# partitions and not into DEFAULT. The runner croaks on a failure, and so
# does an incomplete window.
sub _apply_migrations {
    my $config = GPForum::Config->from_environment;
    my $schema = GPForum::Schema->connect_from_config($config);
    _clear_statement_timeout($schema);
    GPForum::Migration::Runner->new( schema => $schema )->apply_pending;
    my $window = GPForum::Service::Operations::PartitionLifecycle->new(
        schema               => $schema,
        statement_timeout_ms => $config->database_statement_timeout_ms,
    )->ensure_partitions( { apply => 1 } );
    $schema->storage->disconnect;
    if ( !$window->{ok} ) {
        GPForum::X::Check->throw(
                message => 'partition window incomplete after migrate: '
              . scalar( @{ $window->{conflicts} } )
              . ' conflict(s), '
              . scalar( @{ $window->{errors} } )
              . ' error(s)' );
    }

    return;
}

sub _assert_full_schema ($count) {
    if ( $count != _migration_count() ) {
        GPForum::X::Check->throw( message => 'schema_versions count mismatch' );
    }

    return;
}

sub _seed_if_requested ( $self, $options ) {
    return if $options->{seed_profile} eq 'none';

    my $seed = $self->seed;
    if ( !$seed ) {
        GPForum::X::Argument->throw(
            message => 'the staging drill was built without a seed step' );
    }
    my $status = _quietly( sub { return $seed->( $options->{seed_profile} ) } );
    if ( $status != 0 ) {
        GPForum::X::Check->throw(
            message => "seed profile $options->{seed_profile} failed" );
    }

    return;
}

# Every migration up to $max_version that is not applied yet, in order.
sub _apply_through_version ( $database, $max_version ) {
    local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
    my $config = GPForum::Config->from_environment;
    my $schema = GPForum::Schema->connect_from_config($config);
    _clear_statement_timeout($schema);
    my $runner = GPForum::Migration::Runner->new( schema => $schema );
    for my $migration ( @{ $runner->plan->summary } ) {
        next if $migration->{version} gt $max_version;
        next if $runner->applied_versions->{ $migration->{version} };
        $runner->apply_migration($migration);
    }
    $database->{dbh}->do('SELECT 1');

    return;
}

sub _clear_statement_timeout ($schema) {
    my $dbh = GPForum::Infrastructure::Storage->dbh_of($schema);
    return undef if !$dbh;
    $dbh->do('SET statement_timeout = 0');

    return undef;
}

sub _create_throwaway ( $self, $options, $suffix ) {
    my $admin_dsn = $self->_admin_dsn;
    my $prefix    = $options->{database_prefix}
      || sprintf 'gpforum_drill_%d_%d', $PROCESS_ID, time;
    my $name      = "${prefix}_$suffix";
    my $admin_dbh = _connect($admin_dsn);
    $admin_dbh->do( 'CREATE DATABASE ' . $admin_dbh->quote_identifier($name) );
    my $dsn  = $PG_TOOLS->rewrite_dsn( $admin_dsn, $name );
    my $info = {
        admin_dbh => $admin_dbh,
        dbh       => _connect($dsn),
        dsn       => $dsn,
        name      => $name,
    };
    push @{ $self->created }, $info;

    return $info;
}

# The throwaway databases, newest first, unless the operator keeps them.
sub _cleanup ( $self, $evidence, $options ) {
    my @dropped;
    for my $database ( reverse @{ $self->created } ) {
        next if $options->{keep_databases};
        _disconnect( $database->{dbh} );
        my $admin_dbh = $database->{admin_dbh};
        $admin_dbh->do( 'DROP DATABASE IF EXISTS '
              . $admin_dbh->quote_identifier( $database->{name} )
              . ' WITH (FORCE)' );
        _disconnect($admin_dbh);
        push @dropped, $database->{name};
    }
    $evidence->{databases_dropped} = \@dropped;
    delete $evidence->{_fresh};

    return;
}

# A handle that will not close is let go: DROP ... WITH (FORCE) ends the
# throwaway database's sessions anyway, and cleanup must not fail the drill.
sub _disconnect ($dbh) {
    try {
        $dbh->disconnect;
    }
    catch ($error) {
        return undef;
    };

    return undef;
}

sub _require_database_env ($self) {
    my $dsn = $ENV{GPFORUM_DATABASE_DSN};
    if ( !_has_text($dsn) ) {
        GPForum::X::Config->throw(
            message => 'GPFORUM_DATABASE_DSN is required' );
    }
    if ( $dsn !~ /dbname=[^;]+/msx ) {
        GPForum::X::Config->throw( message =>
              'GPFORUM_DATABASE_DSN must name a database with dbname=' );
    }
    $self->admin_dsn($dsn);

    return;
}

sub _admin_dsn ($self) {
    return $self->admin_dsn if _has_text( $self->admin_dsn );

    return $ENV{GPFORUM_DATABASE_DSN};
}

sub _connect ($dsn) {
    return DBI->connect(
        $dsn,
        $ENV{GPFORUM_DATABASE_USER},
        $ENV{GPFORUM_DATABASE_PASSWORD},
        { AutoCommit => 1, PrintError => 0, RaiseError => 1 },
    );
}

sub _row_counts ($dbh) {
    return { map { ( $_ => _table_count( $dbh, $_ ) ) } @SANITY_TABLES };
}

sub _table_count ( $dbh, $table ) {
    my ($count) = $dbh->selectrow_array(
        'SELECT COUNT(*) FROM ' . $dbh->quote_identifier($table) );

    return 0 + $count;
}

sub _schema_version_count ($dbh) {
    return _table_count( $dbh, 'schema_versions' );
}

sub _migration_count {
    return scalar @{ GPForum::Migration::Plan->new->summary };
}

# A phase that did not run, or was skipped, does not fail the drill.
sub _status_from_phases ($evidence) {
    for my $phase (@PHASES) {
        my $result = $evidence->{$phase} or next;
        return 'fail' if !exists $PHASE_OK{ $result->{status} // q{} };
    }

    return 'pass';
}

sub _human_evidence ($evidence) {
    my @lines = ( 'staging-drill status=' . ( $evidence->{status} // 'fail' ) );
    push @lines, map { _human_phase( $_, $evidence->{$_} ) } @PHASES;
    push @lines, 'attachments covered=false root=' . $ATTACHMENTS_ROOT;
    if ( _has_text( $evidence->{error} ) ) {
        push @lines, 'error=' . $evidence->{error};
    }

    return join( "\n", @lines ) . "\n";
}

sub _human_phase ( $name, $phase ) {
    return "$name status=missing" if !$phase;

    my @fields = ("$name status=$phase->{status}");
    push @fields, map { "$_=$phase->{$_}" }
      grep { defined $phase->{$_} } @HUMAN_FIELDS;
    if ( _has_text( $phase->{reason} ) ) {
        push @fields, "reason=$phase->{reason}";
    }

    return join q{ }, @fields;
}

sub _quietly ($code) {
    my $stdout = q{};
    my $stderr = q{};
    open my $out_handle, '>', \$stdout or croak 'failed to capture stdout';
    open my $err_handle, '>', \$stderr or croak 'failed to capture stderr';
    my $status;
    {
        local *STDOUT = $out_handle;
        local *STDERR = $err_handle;
        $status = $code->();
    }
    close $out_handle or croak 'failed to close stdout capture';
    close $err_handle or croak 'failed to close stderr capture';

    return $status;
}

sub _trim_error ($error) {
    $error = "$error";
    $error =~ s/\s+\z//msx;

    return $error;
}

sub _has_text ($value) {
    return defined $value && length $value;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::StagingDrill - Local/staging migrate and restore drill.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $evidence = GPForum::Service::Operations::StagingDrill->new->run($options);

=head1 DESCRIPTION

Creates throwaway PostgreSQL databases, applies migrations, optionally seeds a
small profile, exercises an upgrade-from-previous migration path, and performs a
C<pg_dump>/C<pg_restore> round-trip. Attachment filesystem storage under
C<var/attachments> is documented as out of scope for the dump/restore phase.

=head1 SUBROUTINES/METHODS

=head2 run

Runs the configured drill phases and returns an evidence hashref.

=head2 format_evidence

Formats evidence as JSON or a short human summary.

=head2 exit_status

Returns 0 for C<pass>, otherwise non-zero.

=head2 rewrite_dsn

Rewrites the C<dbname=> segment of a DBI DSN.

=head2 parse_dsn

Parses host/port/dbname from a DBI DSN plus database env credentials.
Both are L<GPForum::Service::Operations::StagingDrill::PgTools>'s.

=head1 DIAGNOSTICS

Throws L<GPForum::X::Config> when the database environment or the client
tools are missing, and L<GPForum::X::Unavailable> when C<pg_dump> or
C<pg_restore> fails (L<GPForum::Service::Operations::StagingDrill::PgTools>).
A verification that fails -- the partition window after
migrate, schema_versions after the first or second migrate, the seed, or the
dump/restore comparison -- throws L<GPForum::X::Check>. The command entry point catches those failures
and emits evidence with C<status=fail>.

=head1 CONFIGURATION AND ENVIRONMENT

Requires C<GPFORUM_DATABASE_DSN>, and typically C<GPFORUM_DATABASE_USER> and
C<GPFORUM_DATABASE_PASSWORD>. Dump/restore needs C<pg_dump> and C<pg_restore>
on C<PATH>, or C<GPFORUM_PG_DUMP> / C<GPFORUM_PG_RESTORE>.

=head1 DEPENDENCIES

Uses migration, seed, and DBI helpers already used by integration tests.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not rehearse nginx, systemd, Hypnotoad, or attachment blob restore.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
