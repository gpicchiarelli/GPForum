# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Cwd           qw(getcwd);
use English       qw(-no_match_vars);
use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(decode_json encode_json);
use Mojo::File    qw(path);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::AntivirusCheck;
use GPForum::Command::DeadLetterCheck;
use GPForum::Command::DeadLetterReplay;
use GPForum::Command::EvidenceValidate;
use GPForum::Command::MailCheck;
use GPForum::Command::MailLifecycleCheck;
use GPForum::Command::Migrate;
use GPForum::Command::OsPreflight;
use GPForum::Command::OutboxDispatch;
use GPForum::Command::PartitionMaintenance;
use GPForum::Command::PlatformCheck;
use GPForum::Command::QueryBudget;
use GPForum::Command::ScheduledJobs;
use GPForum::Command::SearchRebuild;
use GPForum::Command::StagingHostVerify;
use GPForum::Config;
use GPForum::Migration::Plan;
use GPForum::Migration::Runner;
use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Test::DeadLetterReplayer;
use GPForum::Test::DriftedMigrationDbh;
use GPForum::Test::MigrationDbh;
use GPForum::Test::MigrationSchema;
use GPForum::Test::MigrationStorage;
use GPForum::Test::OutboxCommandDispatcher;
use GPForum::Test::PartitionDbh;
use GPForum::Test::QueryBudgetResultSet;
use GPForum::Test::QueryBudgetSchema;
use GPForum::Test::ReadinessRuntime;
use GPForum::Test::ScheduledJobsRunner;
use GPForum::Test::SearchRebuildIndexer;
use GPForum::Test::UnreachableSchema;

our $VERSION = '0.001';

const my $EXIT_OK             => 0;
const my $EXIT_FAILURE        => 1;
const my $EXIT_USAGE          => 2;
const my $LOOP_PASSES         => 2;
const my $LAG_SECONDS         => 42;
const my $THREAD_VIEW_QUERIES => 8;
const my %PASSING             => map { $_ => 1 } qw(pass degraded);

# Quality program, Admin CLI: a machine-readable mode an operator can script.
# Every command that reports state answers --json with one JSON object per
# line on stdout, each carrying "status", with the exit-code contract
# unchanged: 0 ok, 1 a problem, 2 misuse. What the database does with these
# commands is t/integration/postgres-command-json.t.

my $dispatcher = GPForum::Test::OutboxCommandDispatcher->new;
my %command    = (
    'antivirus-check'   => sub { return GPForum::Command::AntivirusCheck->new },
    'dead-letter-check' =>
      sub { return GPForum::Command::DeadLetterCheck->new },
    'dead-letter-replay' => sub {
        return GPForum::Command::DeadLetterReplay->new(
            schema => GPForum::Test::UnreachableSchema->new );
    },
    migrate => sub {
        return GPForum::Command::Migrate->new( runner => _runner('all') );
    },
    'os-preflight' => sub {
        return GPForum::Command::OsPreflight->new(
            config  => GPForum::Config->new,
            runtime => GPForum::Test::ReadinessRuntime->new,
        );
    },
    'outbox-dispatch' => sub {
        return GPForum::Command::OutboxDispatch->new(
            dispatcher => $dispatcher,
            sleeper    => sub { return; },
        );
    },
    'partition-maintenance' => sub {
        return GPForum::Command::PartitionMaintenance->new(
            lifecycle => _lifecycle( _partition_dbh() ) );
    },
    'platform-check' => sub {
        return GPForum::Command::PlatformCheck->new(
            config  => GPForum::Config->new,
            runtime => GPForum::Test::ReadinessRuntime->new,
            schema  => _budget_schema(),
        );
    },
    'query-budget' => sub {
        return GPForum::Command::QueryBudget->new( schema => _budget_schema() );
    },
    'scheduled-jobs' => sub {
        return GPForum::Command::ScheduledJobs->new(
            jobs => GPForum::Test::ScheduledJobsRunner->new(
                summary => {
                    ok       => 1,
                    sessions => { deleted => 2, ok => 1 },
                }
            )
        );
    },
    'search-rebuild' => sub {
        return GPForum::Command::SearchRebuild->new(
            indexer => GPForum::Test::SearchRebuildIndexer->new );
    },
);

# The evidence commands print JSON by default and take --json to say so; their
# status is their own (pass, degraded, fail) and so is what they inspect -- the
# mail settings, the host's deploy files -- so they are asserted apart below.
my %evidence = (
    'evidence-validate' =>
      sub { return GPForum::Command::EvidenceValidate->new },
    'mail-check'           => sub { return GPForum::Command::MailCheck->new },
    'mail-lifecycle-check' =>
      sub { return GPForum::Command::MailLifecycleCheck->new },
    'staging-host-verify' =>
      sub { return GPForum::Command::StagingHostVerify->new },
);

# The scanner a developer's shell may name is not this test's business.
delete local $ENV{GPFORUM_ANTIVIRUS};

# Each mode that reports state: it parses, it says its status, and its exit
# code is the one the human mode gives.
for my $case (
    [ 'antivirus-check',       ['--json'] ],
    [ 'dead-letter-check',     [ '--dry-run', '--json' ] ],
    [ 'migrate',               [ '--plan',    '--json' ] ],
    [ 'migrate',               [ '--check',   '--json' ] ],
    [ 'os-preflight',          ['--json'] ],
    [ 'outbox-dispatch',       [ '--once',    '--json' ] ],
    [ 'partition-maintenance', [ '--plan',    '--json' ] ],
    [ 'platform-check',        [ '--local',   '--json' ] ],
    [ 'platform-check',        [ '--with-db', '--json' ] ],
    [ 'query-budget',          [ '--print',   '--json' ] ],
    [ 'query-budget',          [ '--sync',    '--json' ] ],
    [ 'query-budget',          [ '--check',   '--json' ] ],
    [ 'scheduled-jobs',        ['--json'] ],
    [ 'search-rebuild',        [ '--status', '--json' ] ],
    [ 'search-rebuild',        [ '--entity', 'post', '--json' ] ],
  )
{
    my ( $name, $arguments ) = @{$case};
    my $label  = join q{ }, $name, @{$arguments};
    my $result = _run( $command{$name}->(), @{$arguments} );
    is( $result->{status}, $EXIT_OK, "$label succeeds" );
    my $document = _document( $result, $label );
    ok( defined $document->{status}, "$label carries a status" );
}

# Misuse is still misuse under --json: 2, the usage on stderr, and nothing on
# stdout for a script to mistake for an answer.
for my $name ( sort keys %command, keys %evidence ) {
    my $build  = $command{$name} // $evidence{$name};
    my $result = _run( $build->(), '--json', '--no-such-option' );
    is( $result->{status}, $EXIT_USAGE, "$name --json with a bad option is 2" );
    like( $result->{errors}, qr/Usage:/msx, "$name shows the usage" );
    is( $result->{output}, q{}, "$name prints no document" );
}
for my $case (
    [ 'migrate',        '--plan',  '--apply' ],
    [ 'platform-check', '--local', '--with-db' ],
    [ 'query-budget',   '--print', '--sync' ],
  )
{
    my ( $name, @modes ) = @{$case};
    my $result = _run( $command{$name}->(), @modes, '--json' );
    is( $result->{status}, $EXIT_USAGE, "$name refuses two modes" );
}

_assert_migrate();
_assert_partition_maintenance();
_assert_platform_check();
_assert_query_budget();
_assert_scheduled_jobs();
_assert_outbox_dispatch();
_assert_search_rebuild();
_assert_dead_letter_replay();
_assert_run_failures();
_assert_os_preflight_failure();
_assert_evidence_commands();

done_testing();

sub _assert_migrate {
    my $plan = _document( _run( $command{migrate}->(), '--json' ), 'plan' );
    is( $plan->{command}, 'gpforum-migrate', 'migrate names itself' );
    is( $plan->{mode},    'plan',            'and its mode, plan by default' );
    is(
        scalar @{ $plan->{migrations} },
        scalar @{ GPForum::Migration::Plan->new->summary },
        'and lists every migration'
    );
    is_deeply(
        [ sort keys %{ $plan->{migrations}[0] } ],
        [qw(description file version)],
        'each by version, description and file'
    );

    my $behind = _run( GPForum::Command::Migrate->new( runner => _runner(1) ),
        '--check', '--json' );
    is( $behind->{status}, $EXIT_FAILURE, '--check is 1 when one is pending' );
    my $pending = _document( $behind, 'check' );
    is( $pending->{status},              'fail', 'and says fail' );
    is( scalar @{ $pending->{pending} }, 1,      'naming the one pending' );

    my $human =
      _run( GPForum::Command::Migrate->new( runner => _runner(1) ), '--check' );
    like(
        $human->{output},
qr/^pending [ ] .+ ^migrate [ ] check [ ] status=fail [ ] pending=1$/msx,
        'the lines say the same'
    );

    # A migration that fails is the documented 1, with its reason, where it
    # used to die and leave Perl's 255.
    for my $arguments ( ['--apply'], [ '--apply', '--json' ] ) {
        my $failed = _run(
            GPForum::Command::Migrate->new(
                runner => GPForum::Migration::Runner->new(
                    schema => GPForum::Test::UnreachableSchema->new
                )
            ),
            @{$arguments}
        );
        my $label = join q{ }, @{$arguments};
        is( $failed->{status}, $EXIT_FAILURE, "$label failing is 1" );
        like(
            $failed->{errors},
            qr/the [ ] database [ ] was [ ] reached/msx,
            'with the reason on stderr'
        );
        unlike(
            $failed->{errors},
            qr/[ ] line [ ] \d+/msx,
            'without the code location'
        );
    }
    my $failure = _document(
        _run(
            GPForum::Command::Migrate->new(
                runner => GPForum::Migration::Runner->new(
                    schema => GPForum::Test::UnreachableSchema->new
                )
            ),
            '--apply',
            '--json'
        ),
        'apply'
    );
    is( $failure->{status}, 'fail', 'the failure is a document too' );
    like( $failure->{error}, qr/database/msx, 'carrying the reason' );

    # Each migration commits as it goes, so a run that failed once started
    # may have applied the ones before the failure: an empty "applied" said
    # it had applied none.
    ok( !exists $failure->{applied},
        'without claiming that no migration was applied' );

    _assert_migrate_unreached();
    _assert_migrate_drift();
    _assert_migrate_plan_elsewhere();

    like( GPForum::Command::Migrate->usage_text,
        qr/schema_versions/msx, 'the help names the table it records in' );

    return;
}

# A database never reached applied nothing, and says so. DBI's connect error
# repeats the DSN, so a password the operator put in it must not reach stderr
# or the document. A socket directory that does not exist fails at once,
# without the network.
sub _assert_migrate_unreached {
    local $ENV{GPFORUM_DATABASE_DSN} =
      'dbi:Pg:dbname=gpforum_absent;host=/nonexistent-gpforum;password=hunter2';

    my $unreached = _run( GPForum::Command::Migrate->new, '--apply', '--json' );
    is( $unreached->{status}, $EXIT_FAILURE, 'an unreachable database is 1' );
    my $document = _document( $unreached, 'apply unreached' );
    is_deeply( $document->{applied}, [], 'having applied nothing' );
    like( $document->{error}, qr/DBI/msx, 'with the connect error' );
    unlike( $unreached->{output}, qr/hunter2/msx,
        'the DSN password is not in the document' );
    unlike( $unreached->{errors}, qr/hunter2/msx, 'nor on stderr' );

    return;
}

# An applied migration whose file was edited since: --check fails with the
# reason, under --json and without.
sub _assert_migrate_drift {
    my @applied =
      map { $_->{version} } @{ GPForum::Migration::Plan->new->summary };
    my $drifted = sub {
        return GPForum::Command::Migrate->new(
            runner => GPForum::Migration::Runner->new(
                schema => GPForum::Test::MigrationSchema->new(
                    storage => GPForum::Test::MigrationStorage->new(
                        dbh => GPForum::Test::DriftedMigrationDbh->new(
                            applied_versions => \@applied
                        )
                    )
                )
            )
        );
    };

    my $json = _run( $drifted->(), '--check', '--json' );
    is( $json->{status}, $EXIT_FAILURE, '--check is 1 when a file changed' );
    my $document = _document( $json, 'check drift' );
    is( $document->{status}, 'fail', 'and says fail' );
    like( $document->{error},
        qr/changed [ ] after [ ] they [ ] were [ ] applied/msx,
        'and why' );

    my $human = _run( $drifted->(), '--check' );
    is( $human->{status}, $EXIT_FAILURE, 'so do the lines' );
    like( $human->{errors}, qr/changed [ ] after/msx, 'with the reason' );

    return;
}

# --plan reads migrations/ from the working directory. Run anywhere else, its
# croak escaped uncaught, and Perl took the exit status from $! -- 2, the
# missing directory's ENOENT, which reads as misuse -- with no document.
sub _assert_migrate_plan_elsewhere {
    my @modes = ( '--plan', '--plan --json' );
    my $home  = getcwd();
    chdir tempdir( CLEANUP => 1 ) or croak "chdir: $ERRNO";
    my %result;
    for my $label (@modes) {
        $result{$label} =
          _run( GPForum::Command::Migrate->new, split q{ }, $label );
    }
    chdir $home or croak "chdir $home: $ERRNO";

    for my $label (@modes) {
        my $result = $result{$label};
        is( $result->{status}, $EXIT_FAILURE,
            "$label without migrations/ is a failure, 1" );
        like(
            $result->{errors},
            qr/\A migration [ ] directory [ ] not [ ] found/msx,
            'with the reason on stderr'
        );
        unlike(
            $result->{errors},
            qr/[ ] line [ ] \d+/msx,
            'without the code location'
        );
    }
    my $document = _document( $result{'--plan --json'}, 'plan gone' );
    is( $document->{status}, 'fail', 'and --json still prints a document' );
    is_deeply( $document->{migrations}, [], 'listing no migration' );

    return;
}

sub _assert_partition_maintenance {
    my $plan =
      _document( _run( $command{'partition-maintenance'}->(), '--json' ),
        'partition plan' );
    is( $plan->{mode}, 'plan', 'partition maintenance plans by default' );
    ok( scalar @{ $plan->{planned} }, 'listing the partitions it would make' );
    like(
        $plan->{planned}[0]{create_sql},
        qr/ATTACH [ ] PARTITION/msx,
        'with their DDL'
    );
    is_deeply( $plan->{conflicts}, [], 'and no conflict' );

    my $blocked = _partition_dbh();
    $blocked->default_counts->{audit_log_default} = 1;
    my $conflict = _run(
        GPForum::Command::PartitionMaintenance->new(
            lifecycle => _lifecycle($blocked)
        ),
        '--apply',
        '--json'
    );
    is( $conflict->{status}, $EXIT_FAILURE, 'a conflict is still 1' );
    my $document = _document( $conflict, 'partition conflict' );
    is( $document->{status}, 'fail', 'and says fail' );
    ok( scalar @{ $document->{conflicts}[0]{remediation} },
        'with the remediation the lines print' );

    return;
}

sub _assert_platform_check {
    my $local = _document( _run( $command{'platform-check'}->(), '--json' ),
        'platform local' );
    is( $local->{mode}, 'local', 'platform check is local by default' );
    is_deeply(
        [ map { $_->{name} } @{ $local->{checks} } ],
        [qw(os_preflight operational_profile)],
        'with the checks the lines name'
    );

    my $resultset = GPForum::Test::QueryBudgetResultSet->new;
    my $schema =
      GPForum::Test::QueryBudgetSchema->new( budget_resultset => $resultset );
    GPForum::Service::Operations::QueryBudget->new->sync_schema($schema);
    $resultset->rows->{thread_view}->update( { max_queries => 1 } );
    my $drift = _run(
        GPForum::Command::PlatformCheck->new(
            config  => GPForum::Config->new,
            runtime => GPForum::Test::ReadinessRuntime->new,
            schema  => $schema,
        ),
        '--with-db',
        '--json'
    );
    is( $drift->{status}, $EXIT_FAILURE, 'budget drift is 1' );
    is( _document( $drift, 'platform drift' )->{status},
        'fail', 'and the document says fail' );

    # The database gone is a failure of the run, 1 and a document, where it
    # used to die.
    my $gone = _run(
        GPForum::Command::PlatformCheck->new(
            config  => GPForum::Config->new,
            runtime => GPForum::Test::ReadinessRuntime->new,
            schema  => GPForum::Test::UnreachableSchema->new,
        ),
        '--with-db',
        '--json'
    );
    is( $gone->{status}, $EXIT_FAILURE, 'an unreachable database is 1' );
    is( _document( $gone, 'platform unreachable' )->{status},
        'fail', 'and a document that says fail' );

    return;
}

sub _assert_query_budget {
    my $print = _document( _run( $command{'query-budget'}->(), '--json' ),
        'budget print' );
    is( $print->{endpoints}{thread_view}{max_queries},
        $THREAD_VIEW_QUERIES, 'the catalog is keyed by endpoint' );

    my $resultset = GPForum::Test::QueryBudgetResultSet->new;
    my $schema =
      GPForum::Test::QueryBudgetSchema->new( budget_resultset => $resultset );
    my $budget = GPForum::Command::QueryBudget->new( schema => $schema );
    my $synced = _document( _run( $budget, '--sync', '--json' ), 'sync' );
    ok( $synced->{synced}, '--sync says how many it wrote' );

    $resultset->rows->{thread_view}->update( { max_queries => 1 } );
    my $drift = _run( $budget, '--check', '--json' );
    is( $drift->{status}, $EXIT_FAILURE, 'drift is 1' );
    is_deeply( _document( $drift, 'drift' )->{mismatched},
        ['thread_view'], 'naming the endpoint that drifted' );

    for my $arguments ( ['--check'], [ '--check', '--json' ] ) {
        my $gone = _run(
            GPForum::Command::QueryBudget->new(
                schema => GPForum::Test::UnreachableSchema->new
            ),
            @{$arguments}
        );
        is( $gone->{status}, $EXIT_FAILURE,
            join( q{ }, @{$arguments} ) . ' without a database is 1' );
    }

    return;
}

sub _assert_scheduled_jobs {
    my $summary =
      _document( _run( $command{'scheduled-jobs'}->(), '--json' ), 'jobs' );
    is_deeply(
        $summary->{jobs},
        [ { count => 2, name => 'sessions', ok => 1 } ],
        'each job with the count the line prints'
    );
    _assert_orphan_count();

    my $failed = _run(
        GPForum::Command::ScheduledJobs->new(
            jobs => GPForum::Test::ScheduledJobsRunner->new(
                summary => {
                    attachment_scans =>
                      { error => 'antivirus unavailable', ok => 0 },
                    ok => 0,
                }
            )
        ),
        '--json'
    );
    is( $failed->{status}, $EXIT_FAILURE, 'a failed job is 1' );
    my $document = _document( $failed, 'jobs failed' );
    is( $document->{status},         'fail',                  'and says fail' );
    is( $document->{jobs}[0]{error}, 'antivirus unavailable', 'and why' );

    my $gone = _run(
        GPForum::Command::ScheduledJobs->new(
            jobs => GPForum::Test::ScheduledJobsRunner->new(
                failure => 'database gone'
            )
        ),
        '--json'
    );
    is( $gone->{status}, $EXIT_FAILURE, 'a run that cannot start is 1' );
    is(
        _document( $gone, 'jobs gone' )->{error},
        'database gone',
        'and the document says why'
    );

    return;
}

# The orphan-attachment cleanup answers with the rows it deleted, not a
# number: the line printed "attachments=ARRAY(0x...)", and --json put each
# row -- owner, object key -- where the count belongs.
sub _assert_orphan_count {
    my @orphans = map {
        {
            attachment_id => "orphan-$_",
            object_key    => "objects/orphan-$_",
            owner_user_id => "owner-$_",
        }
    } 1 .. 2;
    my $cleanup = sub {
        return GPForum::Command::ScheduledJobs->new(
            jobs => GPForum::Test::ScheduledJobsRunner->new(
                summary => {
                    attachments => { deleted => [@orphans], ok => 1 },
                    ok          => 1,
                }
            )
        );
    };

    my $result = _run( $cleanup->(), '--json' );
    is_deeply(
        _document( $result, 'orphan cleanup' )->{jobs},
        [ { count => scalar @orphans, name => 'attachments', ok => 1 } ],
        'the orphan cleanup counts the attachments it deleted'
    );
    unlike( $result->{output}, qr/owner-1|objects\//msx,
        'without printing their rows' );
    like(
        _run( $cleanup->() )->{output},
        qr/[ ] attachments=2 (?:[ ]|$)/msx,
        'and the line prints the same count'
    );

    return;
}

sub _assert_outbox_dispatch {
    my $looped = _run( $command{'outbox-dispatch'}->(),
        '--loop', '--max-iterations', $LOOP_PASSES, '--json' );
    my @lines = split /\n/msx, $looped->{output};
    is( scalar @lines, $LOOP_PASSES, '--loop --json prints a line per batch' );
    is_deeply(
        [ sort keys %{ decode_json( $lines[0] ) } ],
        [qw(command dead_lettered dispatched failed selected status)],
        'each with the counts the line prints'
    );

    # Into a pipe or a file, standard output is block-buffered: a batch's
    # line must reach the reader when the batch ends, not once 8 KB of them
    # have piled up.
    my $file = path( tempdir( CLEANUP => 1 ), 'dispatch.jsonl' );
    open my $handle, '>', "$file" or croak "open $file: $ERRNO";
    GPForum::Command::OutboxDispatch->new(
        dispatcher => $dispatcher,
        output     => $handle,
        sleeper    => sub { return; },
    )->run( '--once', '--json' );
    ok( -s "$file", 'the line is written out as the batch ends' );
    close $handle or croak "close $file: $ERRNO";

    return;
}

sub _assert_search_rebuild {
    my $lag =
      _document( _run( $command{'search-rebuild'}->(), '--status', '--json' ),
        'lag' );
    is( $lag->{status},      'ok',         'the command status is ok' );
    is( $lag->{lag_status},  'behind',     'the projection is behind' );
    is( $lag->{lag_seconds}, $LAG_SECONDS, 'by how long' );

    return;
}

sub _assert_dead_letter_replay {
    my $replayed = {
        dead_letter_id => 'first',
        replayed       => { outbox_id => 'outbox-1' },
        status         => 'replayed',
    };
    my $refused = {
        dead_letter_id => 'second',
        error          => 'already replayed',
        status         => 'conflict',
    };
    my $replay = _run(
        GPForum::Command::DeadLetterReplay->new(
            replayer => GPForum::Test::DeadLetterReplayer->new(
                outcomes => [ $replayed, $refused ]
            )
        ),
        '--id', 'first', '--id', 'second', '--json'
    );
    is( $replay->{status}, $EXIT_FAILURE, 'a refused replay is 1' );
    my $document = _document( $replay, 'replay' );
    is( $document->{status}, 'fail', 'and says fail' );
    is_deeply(
        $document->{outcomes},
        [
            {
                dead_letter_id => 'first',
                outbox_id      => 'outbox-1',
                status         => 'replayed'
            },
            {
                dead_letter_id => 'second',
                error          => 'already replayed',
                status         => 'conflict'
            },
        ],
        'with each outcome, replayed or refused'
    );

    # Each replay commits on its own: when the database goes away at the
    # second id, the first is replayed for good, and the document must say
    # so, or a script retrying the run takes it for undone.
    my $gone = _run(
        GPForum::Command::DeadLetterReplay->new(
            replayer => GPForum::Test::DeadLetterReplayer->new(
                outcomes => [ $replayed, 'database gone' ]
            )
        ),
        '--id', 'first', '--id', 'second', '--json'
    );
    is( $gone->{status}, $EXIT_FAILURE, 'a replay the database cut is 1' );
    my $cut = _document( $gone, 'replay cut' );
    is( $cut->{status}, 'fail', 'and says fail' );
    like( $cut->{error}, qr/database [ ] gone/msx, 'and why' );
    is_deeply( [ map { $_->{dead_letter_id} } @{ $cut->{outcomes} } ],
        ['first'], 'keeping the id replayed before the failure' );

    return;
}

# The database gone under the rest of the commands: 1 with the reason on
# stderr, where each used to die with 255, and under --json a document that
# says fail.
sub _assert_run_failures {
    my %gone = (
        'dead-letter-replay --list' => [
            sub {
                return GPForum::Command::DeadLetterReplay->new(
                    schema => GPForum::Test::UnreachableSchema->new );
            },
            '--list',
        ],
        'outbox-dispatch --once' => [
            sub {
                return GPForum::Command::OutboxDispatch->new(
                    app => sub { croak 'the database was reached' } );
            },
            '--once',
        ],
        'partition-maintenance --plan' => [
            sub {
                return GPForum::Command::PartitionMaintenance->new(
                    lifecycle =>
                      GPForum::Service::Operations::PartitionLifecycle->new );
            },
            '--plan',
        ],
        'search-rebuild --status' => [
            sub {
                return GPForum::Command::SearchRebuild->new(
                    schema => GPForum::Test::UnreachableSchema->new );
            },
            '--status',
        ],
    );
    for my $label ( sort keys %gone ) {
        my ( $build, @arguments ) = @{ $gone{$label} };
        my $lines = _run( $build->(), @arguments );
        is( $lines->{status}, $EXIT_FAILURE, "$label failing is 1" );
        like( $lines->{errors}, qr/database/msx, 'with the reason on stderr' );
        is( $lines->{output}, q{}, 'and no line on stdout' );

        # partition-maintenance printed its lines' failure with croak's
        # "at .../PartitionMaintenance.pm line 69." still on, where --json
        # and every other command strip it.
        unlike(
            $lines->{errors},
            qr/[ ] line [ ] \d+/msx,
            'without the code location'
        );

        my $json = _run( $build->(), @arguments, '--json' );
        is( $json->{status}, $EXIT_FAILURE, "$label --json failing is 1" );
        my $document = _document( $json, "$label failing" );
        is( $document->{status}, 'fail', 'and the document says fail' );
        like( $document->{error}, qr/database/msx, 'and why' );
    }

    return;
}

# A setting that does not parse stops os-preflight before it checks anything.
# That was rethrown as an uncaught exception: 255, or whatever $! held -- 2,
# misuse, after a failed file lookup -- and under --json no document at all.
sub _assert_os_preflight_failure {
    local $ENV{GPFORUM_WEB_PROCESSES} = 'many';

    my $lines = _run( GPForum::Command::OsPreflight->new );
    is( $lines->{status}, $EXIT_FAILURE,
        'os-preflight that cannot start is 1' );
    like(
        $lines->{errors},
qr/\A GPFORUM_WEB_PROCESSES [ ] must [ ] be [ ] an [ ] integer \n \z/msx,
        'with the reason alone on stderr'
    );
    is( $lines->{output}, q{}, 'and no report on stdout' );

    my $json = _run( GPForum::Command::OsPreflight->new, '--json' );
    is( $json->{status}, $EXIT_FAILURE,
        'os-preflight --json that cannot start is 1' );
    my $document = _document( $json, 'os-preflight failing' );
    is( $document->{status}, 'fail', 'and the document says fail' );
    like( $document->{error}, qr/GPFORUM_WEB_PROCESSES/msx, 'and why' );
    is_deeply( $document->{checks}, [], 'having run no check' );

    return;
}

# Their status is their own vocabulary, and the exit code follows it: 0 for
# pass or degraded, 1 otherwise.
sub _assert_evidence_commands {
    my $archived = path( tempdir( CLEANUP => 1 ), 'mail.json' );
    $archived->spew(
        encode_json(
            {
                check                => 'mail_delivery',
                mode                 => 'dry_run',
                private_beta_claimed => 0,
                residual_gaps        => ['SMTP send still open'],
                secrets_redacted     => \1,
                status               => 'pass',
            }
        )
    );
    for my $case (
        [ 'evidence-validate',    "$archived" ],
        [ 'mail-check',           '--dry-run' ],
        [ 'mail-lifecycle-check', '--dry-run' ],
        ['staging-host-verify'],
      )
    {
        my ( $name, @arguments ) = @{$case};
        my $result   = _run( $evidence{$name}->(), @arguments, '--json' );
        my $document = _document( $result, $name );
        ok( defined $document->{status}, "$name carries a status" );
        is(
            $result->{status},
            $PASSING{ $document->{status} // q{} } ? $EXIT_OK : $EXIT_FAILURE,
            "$name exits as its status says"
        );
    }

    return;
}

# The command's stdout must be exactly one JSON object on one line.
sub _document {
    my ( $result, $label ) = @_;

    my $output = $result->{output};
    like( $output, qr/\A [^\n]+ \n \z/msx, "$label prints one line" );
    my $document = eval { decode_json($output) };
    ok( ref $document eq 'HASH', "$label is a JSON object" )
      or diag $EVAL_ERROR;

    return $document || {};
}

sub _run {
    my ( $command, @arguments ) = @_;

    my ( $output, $errors ) = ( q{}, q{} );
    my $status;
    {
        open my $stdout, '>', \$output or croak 'capture stdout';
        open my $stderr, '>', \$errors or croak 'capture stderr';
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $status = eval { $command->run(@arguments) };
        if ( !defined $status ) {
            $errors .= "died: $EVAL_ERROR";
        }
        close $stdout or croak 'close stdout';
        close $stderr or croak 'close stderr';
    }

    return { errors => $errors, output => $output, status => $status };
}

# A migration runner over a database that has applied every migration but
# the last $behind of them.
sub _runner {
    my ($behind) = @_;

    my @versions =
      map { $_->{version} } @{ GPForum::Migration::Plan->new->summary };
    if ( $behind ne 'all' ) {
        splice @versions, -$behind;
    }

    return GPForum::Migration::Runner->new(
        schema => GPForum::Test::MigrationSchema->new(
            storage => GPForum::Test::MigrationStorage->new(
                dbh => GPForum::Test::MigrationDbh->new(
                    applied_versions => \@versions
                )
            )
        )
    );
}

sub _budget_schema {
    my $resultset = GPForum::Test::QueryBudgetResultSet->new;
    my $schema =
      GPForum::Test::QueryBudgetSchema->new( budget_resultset => $resultset );
    GPForum::Service::Operations::QueryBudget->new->sync_schema($schema);

    return $schema;
}

sub _lifecycle {
    my ($handle) = @_;

    return GPForum::Service::Operations::PartitionLifecycle->new(
        dbh => $handle );
}

sub _partition_dbh {
    return GPForum::Test::PartitionDbh->new(
        relations => {
            audit_log_default     => 1,
            event_log_default     => 1,
            notifications_default => 1,
        }
    );
}

1;
