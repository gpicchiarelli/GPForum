# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::CLI::outbox_dispatch;
use GPForum::CLI::partition_maintenance;
use GPForum::CLI::query_budget;
use GPForum::CLI::scheduled_jobs;
use GPForum::Command::Migrate;
use GPForum::Command::OutboxDispatch;
use GPForum::Command::PartitionMaintenance;
use GPForum::Command::QueryBudget;
use GPForum::Command::ScheduledJobs;
use GPForum::Command::Support::Words;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Test::CheckRunner;
use GPForum::Test::JobsSummary;
use GPForum::Test::OutboxBatches;
use GPForum::Test::PartitionDbh;
use GPForum::Test::QueryBudgetResultSet;
use GPForum::Test::QueryBudgetSchema;

our $VERSION = '0.001';

# Walkthrough 2, friction 8: five verbs still answered an operator in
# key=value -- `outbox_dispatch selected=3 dispatched=3 ...`, `migrate check
# status=ok pending=0`, a `scheduled_jobs ok=1 ...` line, a partition plan of
# DDL that exited 0 on a database never migrated, and a bare `gpforum
# budgets` that listed the catalog with no verdict. Through the front door
# they say it in the operator's language; their bin/gpforum-* names keep the
# lines the units' journals and older scripts read, and --json is unchanged.

const my $MONTH => qr/\d{4}-\d{2}/msx;

local $ENV{LC_ALL} = 'en_US.UTF-8';
my $english = _words('en');
my $italian = _words('it');

subtest 'gpforum outbox says what it sent' => sub {
    my $sent = _outbox(
        $english,
        [
            {
                selected      => 4,
                dispatched    => 2,
                failed        => 1,
                dead_lettered => 1,
                acknowledged  => 2,
                lost          => 0,
            }
        ],
        '--once'
    );
    is(
        $sent->{output},
        "2 messages sent; 1 to be tried again later; 1 given up on.\n"
          . "Next: see why with gpforum dead-letters --list\n",
        'what was sent, retried and given up on, and where to see why'
    );
    is(
        _outbox( $english, [], '--once' )->{output},
        "Nothing was waiting to be sent.\n",
        'and a batch that found nothing says so'
    );
    is(
        _outbox( $italian,
            [ { selected => 1, dispatched => 1, acknowledged => 1 } ],
            '--once' )->{output},
        "1 messaggio inviato.\n",
        'in Italian'
    );

    my $loop = _outbox(
        $english,
        [ { selected => 0 }, { selected => 3, dispatched => 3 } ],
        qw(--loop --max-iterations 2 --sleep 5)
    );
    is(
        $loop->{output},
        'Sending queued mail and events as they come, looking every 5 s;'
          . " Ctrl-C stops.\n3 messages sent.\n",
        'a loop says what it does once, then only the batches that sent'
    );

    like(
        _outbox(
            $english,       [ { selected => 3, dispatched => 3 } ],
            { human => 0 }, '--once'
        )->{output},
        qr/\A outbox_dispatch [ ] selected=3 [ ] dispatched=3 /msx,
        'bin/gpforum-outbox-dispatch keeps its line'
    );
};

subtest
  'gpforum partitions says how far they reach, and refuses an empty database'
  => sub {
    my $plan = _partitions( $english, _migrated() );
    is( $plan->{status}, 0, 'a plan exits 0' );
    my @plan = split /\n/msx, $plan->{output};
    like(
        $plan[0] // q{},
        qr/\A \d+ [ ] monthly [ ] partitions [ ] to [ ] create,/msx,
        'how many it would create'
    );
    like(
        $plan[0] // q{},
        qr/[ ] up [ ] to [ ] $MONTH [.] \z/msx,
        'up to which month'
    );
    is_deeply(
        [ @plan[ 1 .. $#plan ] ],
        ['Next: gpforum partitions --apply'],
        'and the command'
    );

    my $applied = _partitions( $english, _migrated(), '--apply' );
    like(
        $applied->{output},
qr/\A \N{CHECK MARK} [ ] Created [ ] \d+ [ ] monthly [ ] partitions;/msx,
        'and what it created'
    );
    like(
        $applied->{output},
        qr/[ ] they [ ] reach [ ] $MONTH [.] \n \z/msx,
        'and how far they reach'
    );

    my $empty = _partitions( $english, GPForum::Test::PartitionDbh->new );
    is( $empty->{status}, 1,   'a database never migrated fails' );
    is( $empty->{output}, q{}, 'with no plan of tables that are not there' );
    _has(
        $empty->{errors},
        'The database has no audit_log table yet: apply the migrations with'
          . ' gpforum migrate',
        'but the migrations to apply first'
    );
    like(
        _partitions( $english, GPForum::Test::PartitionDbh->new, '--json' )
          ->{output},
        qr/"unmigrated":\["audit_log","event_log","notifications"\]/msx,
        'which --json names'
    );

    like(
        _partitions( $italian, _migrated() )->{output},
        qr/partizioni [ ] mensili [ ] da [ ] creare/msx,
        'in Italian'
    );
    like(
        _partitions( $english, _migrated(), { human => 0 }, '--plan' )
          ->{output},
        qr/\A partition_maintenance [ ] mode=plan /msx,
        'bin/gpforum-partition-maintenance keeps its lines'
    );
  };

subtest 'gpforum budgets gives a verdict' => sub {
    my $schema = GPForum::Test::QueryBudgetSchema->new(
        budget_resultset => GPForum::Test::QueryBudgetResultSet->new );
    my $drift = _budgets( $english, $schema );
    is( $drift->{status}, 1, 'bare, it checks, and budgets missing fail' );
    like(
        $drift->{output},
        qr/\A \N{BALLOT X} [ ] query [ ] budgets: [ ] \d+ [ ] differ/msx,
        'saying how many differ'
    );
    like( $drift->{output}, qr/^ [ ]{4} Not [ ] in [ ] the [ ] database: /msx,
        'which' );
    like( $drift->{output},
        qr/^ [ ]{4} Fix: [ ] gpforum [ ] budgets [ ] --sync$/msx,
        'and the sync' );

    my $sync = _budgets( $english, $schema, '--sync' );
    like(
        $sync->{output},
qr/\A \N{CHECK MARK} [ ] Synced [ ] the [ ] query [ ] budgets [ ] [(]/msx,
        'a sync says it synced'
    );
    like(
        $sync->{output},
        qr/[(] \d+ [ ] changed [)] [.] \n \z/msx,
        'and how many rows it changed'
    );
    is(
        _budgets( $english, $schema )->{output},
"\N{CHECK MARK} query budgets: as the code sets them\n\nNothing to fix.\n",
        'after which the check passes'
    );
    like(
        _budgets( $italian, $schema )->{output},
        qr/budget [ ] delle [ ] query: [ ] come [ ] li [ ] fissa/msx,
        'in Italian'
    );
    like(
        _budgets( $english, $schema, '--print' )->{output},
        qr/^thread_view [ ] queries=/msx,
        '--print still lists the catalog'
    );
    like(
        GPForum::CLI::query_budget->new->usage,
        qr/--check [^\n]* \n [^\n]* [(]the [ ] default[)]/msx,
        'and the help says the check is the default'
    );
};

subtest 'gpforum migrate --check says whether the schema is current' => sub {
    my $current = _check( $english, [] );
    is( $current->{status}, 0, 'current exits 0' );
    like(
        $current->{output},
qr/\A \N{CHECK MARK} [ ] Schema [ ] is [ ] current [ ] [(]\d+[)][.]\n \z/msx,
        'and says so'
    );

    my $behind = _check(
        $english,
        [
            { version => '052', description => 'one', file => 'a.sql' },
            { version => '053', description => 'two', file => 'b.sql' },
        ]
    );
    is( $behind->{status}, 1, 'behind exits 1' );
    is(
        $behind->{output},
"\N{BALLOT X} 2 migrations to apply, 052 to 053.\nNext: gpforum migrate\n",
        'with what waits and the command'
    );
    like(
        _check( $english, [], default_mode => 'plan' )->{output},
        qr/\A migrate [ ] check [ ] status=ok [ ] pending=0\n \z/msx,
        'bin/gpforum-migrate --check keeps its line'
    );
};

subtest 'gpforum scheduled-jobs says what each job did' => sub {
    my $summary = {
        ok                  => 0,
        sessions            => { deleted => 12 },
        identity_tokens     => { deleted => 1 },
        attachment_scans    => { error   => 'antivirus unavailable', ok => 0 },
        attachment_backfill =>
          { ok => 1, scanned => 0, skipped => 'scanning is off' },
        partitions => { ok => 1, plans => [qw(one two three)] },
    };
    my $run = _jobs( $english, $summary );
    is( $run->{status}, 1, 'a failed job fails the run' );
    is(
        $run->{output},
        join( "\n",
            "\N{CHECK MARK} uploads never scanned: not run (scanning is off)",
            "\N{BALLOT X} uploads waiting for a scan: antivirus unavailable",
            '    Fix: gpforum antivirus-check says why',
            "\N{CHECK MARK} expired sign-in and verification tokens: 1 removed",
            "\N{CHECK MARK} the partition window: checked",
            "\N{CHECK MARK} expired sessions: 12 removed" )
          . "\n",
        'a line a job, named as an operator knows the data'
    ) or diag $run->{output};
    like(
        _jobs( $italian, $summary )->{output},
        qr/sessioni [ ] scadute: [ ] 12 [ ] elementi [ ] rimossi/msx,
        'in Italian'
    );
    like(
        _jobs( $english, $summary, human => 0 )->{output},
        qr/\A scheduled_jobs [ ] ok=0 /msx,
        'bin/gpforum-scheduled-jobs keeps its line'
    );
};

done_testing();

sub _words ($language) {
    return GPForum::Command::Support::Words->new( catalog =>
          GPForum::Service::I18N::CliCatalog->new( language => $language ) );
}

sub _outbox ( $words, $summaries, @arguments ) {
    my %options = _options( \@arguments );

    return _written(
        sub ($handle) {
            return GPForum::Command::OutboxDispatch->new(
                dispatcher =>
                  GPForum::Test::OutboxBatches->new( summaries => $summaries ),
                human   => 1,
                output  => $handle,
                sleeper => sub { return },
                words   => $words,
                %options,
            )->run(@arguments);
        }
    );
}

sub _partitions ( $words, $dbh, @arguments ) {
    my %options = _options( \@arguments );
    my $errors;
    my $run = _written(
        sub ($handle) {
            my $said = _captured(
                sub {
                    return GPForum::Command::PartitionMaintenance->new(
                        lifecycle =>
                          GPForum::Service::Operations::PartitionLifecycle
                          ->new(
                            dbh => $dbh
                          ),
                        human  => 1,
                        output => $handle,
                        words  => $words,
                        %options,
                    )->run(@arguments);
                }
            );
            $errors = $said->{errors};
            return $said->{status};
        }
    );

    return { %{$run}, errors => $errors };
}

sub _budgets ( $words, $schema, @arguments ) {
    return _captured(
        sub {
            return GPForum::Command::QueryBudget->new(
                human  => 1,
                schema => $schema,
                words  => $words,
            )->run(@arguments);
        }
    );
}

sub _check ( $words, $pending, %options ) {
    return _captured(
        sub {
            return GPForum::Command::Migrate->new(
                default_mode => 'apply',
                runner       =>
                  GPForum::Test::CheckRunner->new( pending => $pending ),
                words => $words,
                %options,
            )->run('--check');
        }
    );
}

sub _jobs ( $words, $summary, %options ) {
    return _written(
        sub ($handle) {
            return GPForum::Command::ScheduledJobs->new(
                human => 1,
                jobs  => GPForum::Test::JobsSummary->new( summary => $summary ),
                output => $handle,
                words  => $words,
                %options,
            )->run('--once');
        }
    );
}

# What a command wrote to the handle it was given, decoded, and its status.
sub _written ($code) {
    my $output = q{};
    open my $handle, '>', \$output or croak 'capture';
    my $status = $code->($handle);
    close $handle or croak 'close capture';
    utf8::decode($output);

    return { output => $output, status => $status };
}

sub _has ( $text, $literal, $name ) {
    return ok( index( $text, $literal ) >= 0, $name ) || diag $text;
}

# The default partitions of each table, as the migrations leave them.
sub _migrated {
    return GPForum::Test::PartitionDbh->new(
        relations => {
            audit_log_default     => 1,
            event_log_default     => 1,
            notifications_default => 1,
        }
    );
}

# The command's own attributes, when a test gives them first, as a hash
# reference, taken out of its arguments.
sub _options ($arguments) {
    return () if ref $arguments->[0] ne 'HASH';

    return %{ shift @{$arguments} };
}

sub _captured ($code) {
    my ( $output, $errors ) = ( q{}, q{} );
    my $status;
    {
        open my $stdout, '>', \$output or croak 'capture stdout';
        open my $stderr, '>', \$errors or croak 'capture stderr';
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $status = $code->();
        close $stdout or croak 'close stdout';
        close $stderr or croak 'close stderr';
    }
    utf8::decode($output);
    utf8::decode($errors);

    return { errors => $errors, output => $output, status => $status };
}

1;
