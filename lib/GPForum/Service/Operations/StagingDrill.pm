# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::StagingDrill;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use DBI;
use English       qw(-no_match_vars);
use File::Temp    qw(tempfile);
use IPC::Open3    qw(open3);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base, -signatures;
use Mojo::File qw(path);
use POSIX      qw(WIFEXITED WEXITSTATUS);
use Symbol     qw(gensym);

use GPForum::Config;
use GPForum::Migration::Plan;
use GPForum::Migration::Runner;
use GPForum::Schema;
use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);

our $VERSION = '0.001';

const my $ATTACHMENTS_ROOT   => 'var/attachments';
const my $EXIT_FAILURE       => 1;
const my $PREVIOUS_INDEX_GAP => 1;
const my @SANITY_TABLES      => qw(schema_versions users threads);
const my $ATTACHMENTS_LIMITATION =>
'pg_dump/pg_restore covers PostgreSQL only. Attachment blobs under var/attachments (FilesystemStorage) are not dumped or restored by this drill. Rehearse populated var/attachments blob restore with script/staging-drill-attachments; back up live operator trees separately.';
const my $RESIDUAL_DEPLOY_GAP =>
'Live Hypnotoad/TLS host bring-up remains manual; run script/staging-drill-attachments for nginx/systemd template checks (static plus host verify/-t when tools exist) and populated var/attachments restore.';
const my $RESIDUAL_BETA_GAP =>
  'This drill does not claim private-beta readiness.';

has admin_dsn => undef;

# The seed step. The performance seed is a command, a layer above this
# service, so the command that builds the drill hands it in rather than the
# service reaching up for it. Called with the profile name; returns an exit
# status.
has seed    => undef;
has created => sub { return [] };
has tools   => undef;

sub run ( $self, $options ) {
    my $evidence = _base_evidence($options);
    my $ok       = eval {
        $self->_execute( $evidence, $options );
        return 1;
    };
    if ( !$ok ) {
        $evidence->{status} = 'fail';
        $evidence->{error}  = _trim_error($EVAL_ERROR);
    }
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
    return _rewrite_dsn( $dsn, $dbname );
}

sub parse_dsn ( $self, $dsn ) {
    return _parse_dsn($dsn);
}

sub _execute ( $self, $evidence, $options ) {
    $self->_require_database_env;
    $self->_require_pg_tools($options);
    $self->_run_fresh_phase( $evidence, $options );
    $self->_run_upgrade_phase( $evidence, $options );
    $self->_run_dump_restore_phase( $evidence, $options );

    return;
}

sub _run_fresh_phase ( $self, $evidence, $options ) {
    my $database = $self->_create_throwaway( $options, 'fresh' );
    local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
    _apply_migrations();
    my $counts = _row_counts( $database->{dbh} );
    _apply_migrations();
    _assert_unchanged_schema_versions( $database->{dbh},
        $counts->{schema_versions} );
    _assert_full_schema( $counts->{schema_versions} );
    $evidence->{fresh_migrate} =
      _fresh_pass( $database->{name}, $counts->{schema_versions} );
    $evidence->{_fresh} = $database;

    return;
}

sub _fresh_pass ( $name, $schema_versions ) {
    return {
        status              => 'pass',
        database            => $name,
        schema_versions     => $schema_versions,
        expected_migrations => _migration_count(),
        second_apply_delta  => 0,
    };
}

sub _run_upgrade_phase ( $self, $evidence, $options ) {
    my $skipped = _upgrade_skip_reason($options);
    if ($skipped) {
        $evidence->{upgrade_path} = $skipped;
        return;
    }

    my $plan     = GPForum::Migration::Plan->new->summary;
    my $database = $self->_create_throwaway( $options, 'upgrade' );
    local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
    my $boundary = _upgrade_boundary($plan);
    _apply_through_version( $database, $boundary->{previous} );
    my $before = _schema_version_count( $database->{dbh} );
    _apply_migrations();
    my $after = _schema_version_count( $database->{dbh} );
    _assert_full_schema($after);
    $evidence->{upgrade_path} = {
        status                 => 'pass',
        database               => $database->{name},
        from_version           => $boundary->{previous},
        to_version             => $boundary->{latest},
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

    my $undefined;
    return $undefined;
}

sub _upgrade_boundary ($plan) {
    my $last_index = $#{$plan};

    return {
        previous => $plan->[ $last_index - $PREVIOUS_INDEX_GAP ]{version},
        latest   => $plan->[$last_index]{version},
    };
}

sub _run_dump_restore_phase ( $self, $evidence, $options ) {
    if ( $options->{skip_dump_restore} ) {
        $evidence->{dump_restore} = {
            status => 'skipped',
            reason => 'operator passed --skip-dump-restore',
        };
        return;
    }

    my $source = $evidence->{_fresh}
      || croak 'dump/restore requires a successful fresh migrate phase';
    local $ENV{GPFORUM_DATABASE_DSN} = $source->{dsn};
    $self->_seed_if_requested($options);
    my $before = _row_counts( $source->{dbh} );
    my $dump   = _temp_dump_path();
    $self->_pg_dump( $source, $dump );
    my $target = $self->_create_throwaway( $options, 'restore' );
    $self->_pg_restore( $target, $dump );
    unlink $dump;
    my $after = _row_counts( $target->{dbh} );
    _assert_counts_match( $before, $after );
    $evidence->{dump_restore} = _dump_pass( $source, $target, $after );

    return;
}

sub _dump_pass ( $source, $target, $after ) {
    return {
        status           => 'pass',
        source_database  => $source->{name},
        restore_database => $target->{name},
        schema_versions  => $after->{schema_versions},
        users            => $after->{users},
        threads          => $after->{threads},
    };
}

# What migrate --apply does: every pending migration, in order, with the
# statement timeout lifted for long DDL. The runner croaks on a failure.
sub _apply_migrations {
    my $schema =
      GPForum::Schema->connect_from_config( GPForum::Config->from_environment );
    _clear_statement_timeout($schema);
    GPForum::Migration::Runner->new( schema => $schema )->apply_pending;
    $schema->storage->disconnect;

    return;
}

sub _assert_unchanged_schema_versions ( $dbh, $expected ) {
    my $after = _schema_version_count($dbh);
    croak 'second migrate changed schema_versions' if $after != $expected;

    return;
}

sub _assert_full_schema ($count) {
    croak 'schema_versions count mismatch' if $count != _migration_count();

    return;
}

sub _seed_if_requested ( $self, $options ) {
    return if $options->{seed_profile} eq 'none';

    my $seed = $self->seed
      or croak 'the staging drill was built without a seed step';
    my $status = _quietly( sub { return $seed->( $options->{seed_profile} ) } );
    croak "seed profile $options->{seed_profile} failed" if $status != 0;

    return;
}

sub _apply_through_version ( $database, $max_version ) {
    local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
    my $config = GPForum::Config->from_environment;
    my $schema = GPForum::Schema->connect_from_config($config);
    _clear_statement_timeout($schema);
    my $runner = GPForum::Migration::Runner->new( schema => $schema );
    _apply_runner_through( $runner, $max_version );
    $database->{dbh}->do('SELECT 1');

    return;
}

sub _apply_runner_through ( $runner, $max_version ) {
    for my $migration ( @{ $runner->plan->summary } ) {
        next if $migration->{version} gt $max_version;
        next if $runner->applied_versions->{ $migration->{version} };
        $runner->apply_migration($migration);
    }

    return;
}

sub _clear_statement_timeout ($schema) {
    my $undefined;

    my $dbh = eval { return $schema->storage->dbh; };
    return $undefined if !$dbh;
    $dbh->do('SET statement_timeout = 0');

    return $undefined;
}

sub _create_throwaway ( $self, $options, $suffix ) {
    my $admin_dsn = $self->_admin_dsn;
    my $name      = _database_name( $options, $suffix );
    my $admin_dbh = _connect($admin_dsn);
    $admin_dbh->do( 'CREATE DATABASE ' . $admin_dbh->quote_identifier($name) );
    my $dsn  = _rewrite_dsn( $admin_dsn, $name );
    my $info = {
        admin_dbh => $admin_dbh,
        dbh       => _connect($dsn),
        dsn       => $dsn,
        name      => $name,
    };
    push @{ $self->created }, $info;

    return $info;
}

sub _cleanup ( $self, $evidence, $options ) {
    my @dropped;
    for my $database ( reverse @{ $self->created } ) {
        next if $options->{keep_databases};
        _drop_database($database);
        push @dropped, $database->{name};
    }
    $evidence->{databases_dropped} = \@dropped;
    delete $evidence->{_fresh};

    return;
}

sub _drop_database ($database) {
    my $closed = eval { $database->{dbh}->disconnect; 1; };
    if ( !$closed ) {
        _trim_error($EVAL_ERROR);
    }
    my $admin_dbh = $database->{admin_dbh};
    $admin_dbh->do( 'DROP DATABASE IF EXISTS '
          . $admin_dbh->quote_identifier( $database->{name} )
          . ' WITH (FORCE)' );
    my $admin_closed = eval { $admin_dbh->disconnect; 1; };
    if ( !$admin_closed ) {
        _trim_error($EVAL_ERROR);
    }

    return;
}

sub _require_database_env ($self) {
    my $dsn = $ENV{GPFORUM_DATABASE_DSN};
    croak 'GPFORUM_DATABASE_DSN is required' if !_has_text($dsn);
    croak 'GPFORUM_DATABASE_DSN must name a database with dbname='
      if $dsn !~ /dbname=[^;]+/msx;
    $self->admin_dsn($dsn);

    return;
}

sub _require_pg_tools ( $self, $options ) {
    return if $options->{skip_dump_restore};

    my $tools = {
        pg_dump    => _find_pg_tool('pg_dump'),
        pg_restore => _find_pg_tool('pg_restore'),
    };
    croak 'pg_dump not found on PATH (set GPFORUM_PG_DUMP)'
      if !_has_text( $tools->{pg_dump} );
    croak 'pg_restore not found on PATH (set GPFORUM_PG_RESTORE)'
      if !_has_text( $tools->{pg_restore} );
    $self->tools($tools);

    return;
}

sub _pg_dump ( $self, $database, $dump_path ) {
    my $parts   = _parse_dsn( $database->{dsn} );
    my @command = (
        $self->tools->{pg_dump},
        '--format=custom',
        '--file=' . $dump_path,
        _pg_connection_args($parts),
        $parts->{dbname},
    );
    _run_pg_command( \@command, $parts->{password} );

    return;
}

sub _pg_restore ( $self, $database, $dump_path ) {
    my $parts   = _parse_dsn( $database->{dsn} );
    my @command = (
        $self->tools->{pg_restore},
        '--no-owner', '--no-acl',
        '--dbname=' . $parts->{dbname},
        _pg_connection_args($parts), $dump_path,
    );
    _run_pg_command( \@command, $parts->{password} );

    return;
}

sub _pg_connection_args ($parts) {
    my @args;
    if ( _has_text( $parts->{host} ) ) {
        push @args, '--host=' . $parts->{host};
    }
    if ( _has_text( $parts->{port} ) ) {
        push @args, '--port=' . $parts->{port};
    }
    if ( _has_text( $parts->{user} ) ) {
        push @args, '--username=' . $parts->{user};
    }

    return @args;
}

sub _run_pg_command ( $command, $password ) {
    if ( defined $password ) {
        local $ENV{PGPASSWORD} = $password;
        _capture_command($command);
        return;
    }
    _capture_command($command);

    return;
}

sub _capture_command ($command) {
    my $stderr = gensym;
    my $pid    = open3( my $stdin, my $stdout, $stderr, @{$command} );
    close $stdin or croak 'failed to close pg command stdin';
    my $output = _slurp_handles( $stdout, $stderr );
    waitpid $pid, 0;
    _assert_command_ok( $command, $output, $CHILD_ERROR );

    return $output;
}

sub _slurp_handles ( $stdout, $stderr ) {
    my $output = q{};
    $output .= _slurp_handle($stdout);
    $output .= _slurp_handle($stderr);

    return $output;
}

sub _slurp_handle ($handle) {
    my $output = q{};
    while ( my $line = <$handle> ) {
        $output .= $line;
    }
    close $handle or croak 'failed to close pg command handle';

    return $output;
}

sub _assert_command_ok ( $command, $output, $status ) {
    return if WIFEXITED($status) && WEXITSTATUS($status) == 0;
    croak 'pg command failed: '
      . join( q{ }, @{$command} ) . "\n"
      . _trim_error($output);
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

sub _rewrite_dsn ( $dsn, $dbname ) {
    croak 'GPFORUM_DATABASE_DSN must name a database with dbname='
      if $dsn !~ /dbname=[^;]+/msx;
    ( my $rewritten = $dsn ) =~ s/dbname=[^;]+/dbname=$dbname/msx;

    return $rewritten;
}

sub _parse_dsn ($dsn) {
    my %parts = (
        dbname   => undef,
        host     => undef,
        port     => undef,
        user     => $ENV{GPFORUM_DATABASE_USER},
        password => $ENV{GPFORUM_DATABASE_PASSWORD},
    );
    _fill_dsn_parts( \%parts, $dsn );
    croak 'DSN is missing dbname=' if !_has_text( $parts{dbname} );

    return \%parts;
}

sub _fill_dsn_parts ( $parts, $dsn ) {
    if ( $dsn =~ /dbname=([^;]+)/msx ) {
        $parts->{dbname} = $1;
    }
    if ( $dsn =~ /host=([^;]+)/msx ) {
        $parts->{host} = $1;
    }
    if ( $dsn =~ /port=([^;]+)/msx ) {
        $parts->{port} = $1;
    }

    return;
}

sub _database_name ( $options, $suffix ) {
    my $prefix = $options->{database_prefix} || sprintf 'gpforum_drill_%d_%d',
      $PROCESS_ID, time;

    return sprintf '%s_%s', $prefix, $suffix;
}

sub _row_counts ($dbh) {
    my %counts;
    for my $table (@SANITY_TABLES) {
        $counts{$table} = _table_count( $dbh, $table );
    }

    return \%counts;
}

sub _table_count ( $dbh, $table ) {
    my ($count) = $dbh->selectrow_array(
        'SELECT COUNT(*) FROM ' . $dbh->quote_identifier($table) );

    return 0 + $count;
}

sub _schema_version_count ($dbh) {
    return _table_count( $dbh, 'schema_versions' );
}

sub _assert_counts_match ( $before, $after ) {
    for my $table (@SANITY_TABLES) {
        croak
          "restore mismatch on $table: $before->{$table} vs $after->{$table}"
          if $before->{$table} != $after->{$table};
    }

    return;
}

sub _migration_count {
    return scalar @{ GPForum::Migration::Plan->new->summary };
}

sub _temp_dump_path {
    my ( $fh, $path ) = tempfile( 'gpforum-drill-XXXXXX', SUFFIX => '.dump' );
    close $fh or croak 'failed to close temporary dump handle';

    return $path;
}

sub _find_pg_tool ($name) {
    my $from_env = _pg_tool_from_env($name);
    return $from_env if _has_text($from_env);

    my $from_path = _which($name);
    return $from_path if _has_text($from_path);

    return _pg_tool_from_candidates($name);
}

sub _pg_tool_from_env ($name) {
    my $env_key = 'GPFORUM_' . uc $name;
    return $ENV{$env_key}
      if _has_text( $ENV{$env_key} ) && -x $ENV{$env_key};

    my $undefined;
    return $undefined;
}

sub _pg_tool_from_candidates ($name) {
    for my $candidate ( _pg_tool_candidates($name) ) {
        return $candidate if -x $candidate;
    }

    my $undefined;
    return $undefined;
}

sub _which ($name) {
    for my $dir ( split /:/msx, ( $ENV{PATH} // q{} ) ) {
        my $path = path( $dir, $name )->to_string;
        return $path if -x $path;
    }

    my $undefined;
    return $undefined;
}

sub _pg_tool_candidates ($name) {
    return (
        "/usr/lib/postgresql/16/bin/$name",
        "/usr/lib/postgresql/15/bin/$name",
        "/usr/lib/postgresql/14/bin/$name",
        "/usr/bin/$name",
        "/usr/local/bin/$name",
        "/opt/homebrew/opt/libpq/bin/$name",
        "/usr/local/opt/libpq/bin/$name",
        "/Applications/Postgres.app/Contents/Versions/latest/bin/$name",
    );
}

sub _base_evidence ($options) {
    return {
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
}

sub _status_from_phases ($evidence) {
    for my $phase (qw(fresh_migrate upgrade_path dump_restore)) {
        return 'fail' if !_phase_ok( $evidence->{$phase} );
    }

    return 'pass';
}

sub _phase_ok ($result) {
    return 1 if !$result;
    return 1 if ( $result->{status} // q{} ) eq 'skipped';
    return 1 if ( $result->{status} // q{} ) eq 'pass';

    return 0;
}

sub _human_evidence ($evidence) {
    my @lines = ( 'staging-drill status=' . ( $evidence->{status} // 'fail' ) );
    push @lines, _human_phase( 'fresh_migrate', $evidence->{fresh_migrate} );
    push @lines, _human_phase( 'upgrade_path',  $evidence->{upgrade_path} );
    push @lines, _human_phase( 'dump_restore',  $evidence->{dump_restore} );
    push @lines, 'attachments covered=false root=' . $ATTACHMENTS_ROOT;
    if ( _has_text( $evidence->{error} ) ) {
        push @lines, 'error=' . $evidence->{error};
    }

    return join( "\n", @lines ) . "\n";
}

sub _human_phase ( $name, $phase ) {
    return "$name status=missing" if !$phase;

    return join q{ }, "$name status=$phase->{status}",
      _human_phase_fields($phase);
}

sub _human_phase_fields ($phase) {
    return (
        _optional_field( 'schema_versions', $phase->{schema_versions} ),
        _optional_field(
            'schema_versions_after', $phase->{schema_versions_after}
        ),
        _optional_field( 'users',   $phase->{users} ),
        _optional_field( 'threads', $phase->{threads} ),
        _optional_text_field( 'reason', $phase->{reason} ),
    );
}

sub _optional_field ( $name, $value ) {
    return () if !defined $value;

    return "$name=$value";
}

sub _optional_text_field ( $name, $value ) {
    return () if !_has_text($value);

    return "$name=$value";
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

=head1 DIAGNOSTICS

Croaks when database environment, client tools, migrations, seed, or
dump/restore verification fail. The command entry point catches those failures
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
