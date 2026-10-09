# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use JSON::PP ();
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::AdminBootstrap;
use GPForum::Command::DeadLetterReplay;
use GPForum::Command::HypnotoadBenchmark;
use GPForum::Command::HypnotoadScaling;
use GPForum::Command::PerformanceSeed;
use GPForum::Command::QueryPlanEvidence;
use GPForum::Command::SearchRebuild;
use GPForum::Command::StagingDrillAttachments;
use GPForum::Command::StagingHostVerify;
use GPForum::Command::StressLoad;
use GPForum::Test::PhaseDrill;
use GPForum::Test::RecordingEvidenceService;
use GPForum::Test::ReplacedSubs qw(with_replaced_subs);
use GPForum::Test::SeedOptionsRecorder;
use GPForum::Test::TransactionDbh;
use GPForum::X::Usage;

our $VERSION = '0.001';

# What the option parsers accept, refuse and hand on, now that they throw
# GPForum::X::Usage instead of croaking their usage text and fold their
# per-flag helpers into one loop each: the operator's bytes, the exit status
# and the values the work receives are the parsers' contract.

const my $EXIT_OK    => 0;
const my $EXIT_USAGE => 2;

# The dataset each profile seeds: users, categories, threads, posts per thread.
const my %DATASET => (
    small        => [ 5,  3, 12,  8 ],
    medium       => [ 25, 8, 120, 15 ],
    'hot-thread' => [ 10, 3, 30,  120 ],
);

# staging-drill-attachments: the attachment and deploy phases' statuses, and
# the drill's ('none' is a phase that answers without one).
const my %COMBINED => (
    'pass pass'         => 'pass',
    'pass degraded'     => 'degraded',
    'degraded degraded' => 'degraded',
    'degraded fail'     => 'fail',
    'fail degraded'     => 'fail',
    'pass fail'         => 'fail',
    'pass bogus'        => 'fail',
    'pass none'         => 'fail',
    'skipped degraded'  => 'degraded',
    'degraded skipped'  => 'degraded',
    'skipped pass'      => 'pass',
    'skipped fail'      => 'fail',
);

const my @STRESS_ARGUMENTS => (
    qw(--dry-run --profile 100 --concurrency 3 --requests-per-client 2),
    qw(--request-timeout 9 --max-error-rate .5 --p95-limit-ms 10),
    qw(--route /x --route /y --base-url http://127.0.0.1:1),
);

const my %STRESS_REFUSED => (
    'a concurrency of 0'        => [qw(--concurrency 0)],
    'a concurrency of x'        => [qw(--concurrency x)],
    'a timeout of 01'           => [qw(--request-timeout 01)],
    'an error rate of 1.'       => [qw(--max-error-rate 1.)],
    'an error rate below zero'  => [qw(--max-error-rate -1)],
    'a p95 limit with no value' => [qw(--p95-limit-ms)],
);

_test_admin_bootstrap();
_test_misuse_by_class();
_test_stress_load();
_test_staging_host_verify();
_test_staging_drill_attachments();
_test_seed_profile();
_test_scaling_seed();
_test_hypnotoad_seed();
_test_explain_transaction();
_test_seed_transaction();

done_testing();

# admin-bootstrap: an option it does not know is a usage error that says
# what was wrong, then gives the usage text once -- it printed the text twice,
# and nothing else -- and not Perl's complaint about a key the constant flag
# table lacks.
sub _test_admin_bootstrap {
    my $usage = GPForum::Command::AdminBootstrap->usage_text;
    for my $case (
        [ ['--unknown'],               '--unknown is not an option' ],
        [ ['zzz'],                     q{'zzz' is not something} ],
        [ [qw(--user-id 1 --bogus x)], '--bogus is not an option' ],
        [ [qw(--user-id -1)],          '--user-id needs a value' ],
        [ ['--user-id'],               '--user-id needs a value' ],
        [ [qw(--role-name admin)],     'Say whom to make the owner' ],
      )
    {
        my ( $arguments, $reason ) = @{$case};
        my $label = join q{ }, @{$arguments};
        my $result =
          _run( GPForum::Command::AdminBootstrap->new, @{$arguments} );
        is( $result->{status}, $EXIT_USAGE,
            "admin-bootstrap $label is misuse" );
        is( index( $result->{errors}, $reason ),
            0, "admin-bootstrap $label says what was wrong" );
        my $at = index $result->{errors}, 'Usage:';
        is( substr( $result->{errors}, $at ),
            _terminated($usage), 'then the usage text, once' );
    }
    return;
}

# The commands that ask Command::Usage->is_usage, which knows misuse only by
# its class now: two rethrow anything else, two name the unknown option.
sub _test_misuse_by_class {
    for my $class (qw(QueryPlanEvidence PerformanceSeed)) {
        my $full   = "GPForum::Command::$class";
        my $result = _run( $full->new, '--bogus' );
        is( $result->{died},   undef,       "$class --bogus does not die" );
        is( $result->{status}, $EXIT_USAGE, "$class --bogus is misuse" );
        is(
            $result->{errors},
            "--bogus is not an option of this command.\n\n"
              . _terminated( $full->usage_text ),
            "$class --bogus says so, then prints its usage text"
        );
    }
    for my $class (qw(DeadLetterReplay SearchRebuild)) {
        my $full   = "GPForum::Command::$class";
        my $result = _run( $full->new, '--bogus' );
        is( $result->{status}, $EXIT_USAGE, "$class --bogus is misuse" );
        is(
            $result->{errors},
            "Unknown option: --bogus\n\n" . _terminated( $full->usage_text ),
            "$class --bogus names the option, then the usage"
        );
    }

    return;
}

# stress-load hands the work numbers, not the strings typed, and refuses a
# value of the wrong shape as misuse.
sub _test_stress_load {
    my $service = GPForum::Test::RecordingEvidenceService->new;
    my $command = GPForum::Command::StressLoad->new( load => $service );
    my $usage   = GPForum::Command::StressLoad->usage_text;

    my $result = _run( $command, @STRESS_ARGUMENTS );
    is( $result->{status}, $EXIT_OK, 'stress-load accepts every value option' );
    my %options = %{ $service->options };
    is(
        JSON::PP->new->encode(
            [
                @options{
                    qw(concurrency requests_per_client request_timeout
                      max_error_rate p95_limit_ms)
                }
            ]
        ),
        '[3,2,9,0.5,10]',
        'stress-load passes its numbers as numbers'
    );
    is_deeply( $options{routes}, [qw(/x /y)], 'and every route, in order' );
    is( $options{profile},  '100',                'and the profile as typed' );
    is( $options{base_url}, 'http://127.0.0.1:1', 'and the base URL' );

    for my $label ( sort keys %STRESS_REFUSED ) {
        my $refusal =
          _run( $command, '--dry-run', @{ $STRESS_REFUSED{$label} } );
        is( $refusal->{status}, $EXIT_USAGE, "stress-load refuses $label" );
        is( $refusal->{errors}, _terminated($usage), 'with its usage text' );
    }
    my $route = _run( $command, qw(--dry-run --route x) );
    is( $route->{status}, $EXIT_USAGE,
        'stress-load refuses a route without a slash' );
    is(
        $route->{errors},
        "Unsupported route: x\n" . _terminated($usage),
        'and says which'
    );

    return;
}

# staging-host-verify takes --timeout as a number, and names the option a
# value is missing for.
sub _test_staging_host_verify {
    my $service = GPForum::Test::RecordingEvidenceService->new;
    my $command =
      GPForum::Command::StagingHostVerify->new( verify => $service );
    my $usage = GPForum::Command::StagingHostVerify->usage_text;

    my $result = _run( $command, qw(--timeout 7) );
    is( $result->{status}, $EXIT_OK, 'staging-host-verify takes --timeout 7' );
    is( JSON::PP->new->encode( [ $service->options->{timeout} ] ),
        '[7]', 'and passes it as a number' );

    my $bad = _run( $command, qw(--timeout 7s) );
    is( $bad->{status}, $EXIT_USAGE, 'staging-host-verify refuses 7s' );
    is(
        $bad->{errors},
        "Invalid --timeout\n" . _terminated($usage),
        'as an invalid timeout'
    );
    for my $option (
        qw(--env-file --unit-dir --nginx-conf --base-url --metrics-token))
    {
        is(
            _run( $command, $option )->{errors},
            "Missing value for $option\n" . _terminated($usage),
            "staging-host-verify names $option when its value is missing"
        );
    }

    return;
}

# staging-drill-attachments: a phase that degraded degrades the drill, one
# that failed or gave no status fails it, and a skipped one does not count.
sub _test_staging_drill_attachments {
    for my $phases ( sort keys %COMBINED ) {
        my ( $attachments, $deploy ) = split /[ ]/msx, $phases;
        my @skipped;
        if ( $attachments eq 'skipped' ) {
            push @skipped, '--skip-attachments';
        }
        if ( $deploy eq 'skipped' ) {
            push @skipped, '--skip-deploy';
        }
        my $command = GPForum::Command::StagingDrillAttachments->new(
            attachment_drill => _phase($attachments),
            deploy_drill     => _phase($deploy),
        );

        my $result = _run( $command, '--json', @skipped );
        is( JSON::PP->new->decode( $result->{output} )->{status},
            $COMBINED{$phases},
            "phases $phases combine to $COMBINED{$phases}" );
    }

    return;
}

sub _phase ($status) {
    return GPForum::Test::PhaseDrill->new(
        status => $status eq 'none' ? undef : $status );
}

# seed_profile seeds the numbers --profile gives.
sub _test_seed_profile {
    for my $profile ( sort keys %DATASET ) {
        my $options =
          GPForum::Test::SeedOptionsRecorder->new->seed_profile($profile);
        is_deeply(
            [ @{$options}{qw(users categories threads posts_per_thread)} ],
            $DATASET{$profile}, "the $profile profile seeds its dataset" );
        is( $options->{profile}, $profile, 'under its own name' );
        is( $options->{dry_run}, 0,        'for real' );
        is( $options->{format},  'text',   'reporting as text' );
    }

    my $refused;
    try {
        GPForum::Test::SeedOptionsRecorder->new->seed_profile('huge');
    }
    catch ($error) {
        $refused = $error;
    };
    ok( GPForum::X::Usage->caught($refused), 'an unknown profile is misuse' );

    return;
}

# hypnotoad-scaling seeds its profile through seed_profile, once, and only
# when told to seed for real.
sub _test_scaling_seed {
    my @seeded;
    my %options = (
        worker_counts => [$EXIT_USAGE],
        routes        => [q{/}],
        profile       => 'medium',
        seed          => 1,
        dry_run       => 0,
    );
    my $scaling = GPForum::Command::HypnotoadScaling->new;
    my $report  = sub (%overrides) {
        return $scaling->scaling_report( { %options, %overrides } );
    };

    _with_seed_recorded(
        \@seeded,
        sub {
            with_replaced_subs(
                q{GPForum::Command::HypnotoadBenchmark},
                { benchmark_report => sub { return { status => 'ok' } } },
                sub {
                    $report->();
                    is_deeply( \@seeded, ['medium'],
                        'hypnotoad-scaling seeds its profile' );
                    $report->( dry_run => 1 );
                    $report->( seed    => 0 );
                }
            );
        }
    );
    is_deeply( \@seeded, ['medium'],
        'but not on a dry run, nor without --seed' );

    return;
}

# hypnotoad-benchmark seeds before it starts the server; the server itself is
# not started here, the step after the seed stops the run.
sub _test_hypnotoad_seed {
    my @seeded;
    my $benchmark = sub ($seed) {
        GPForum::Command::HypnotoadBenchmark->new->benchmark_report(
            { seed => $seed, profile => 'hot-thread', dry_run => 0 } );
    };

    for my $seed ( 1, 0 ) {
        my $stopped;
        try {
            _with_seed_recorded(
                \@seeded,
                sub {
                    with_replaced_subs(
                        q{GPForum::Command::HypnotoadBenchmark},
                        {
                            _assert_database_available => sub { return },
                            _start_hypnotoad           =>
                              sub { croak 'stopped before the server' },
                        },
                        sub { $benchmark->($seed) }
                    );
                }
            );
        }
        catch ($error) {
            $stopped = $error;
        };
        like(
            $stopped,
            qr/\Astopped[ ]before[ ]the[ ]server/msx,
            'hypnotoad-benchmark goes on to start the server'
        );
    }
    is_deeply( \@seeded, ['hot-thread'],
        'hypnotoad-benchmark seeds its profile only with --seed' );

    return;
}

# The query plan's EXPLAIN runs in a transaction it always rolls back, and a
# statement that fails is the error, not a partial plan.
sub _test_explain_transaction {
    my $dbh   = GPForum::Test::TransactionDbh->new;
    my $plans = _explain( $dbh, ['SELECT 1'] );
    is_deeply( [ sort keys %{$plans} ], [qw(forced plan)], 'both plans' );
    is( $dbh->calls->[-1], 'rollback', 'read in a rolled-back transaction' );

    my $failing = GPForum::Test::TransactionDbh->new( fail_on_select => 1 );
    my $error;
    try {
        _explain( $failing, ['SELECT 1'] );
    }
    catch ($caught) {
        $error = $caught;
    };
    like( $error, qr/\Aexplain[ ]failed/msx, 'a failed EXPLAIN is the error' );
    is( $failing->calls->[-1], 'rollback', 'raised after the rollback' );

    return;
}

# The seed's transaction: committed when the work succeeds, rolled back and
# the work's error kept when it fails, even when the rollback fails too.
sub _test_seed_transaction {
    my $dbh = GPForum::Test::TransactionDbh->new;
    _with_transaction( $dbh, sub { return } );
    is( $dbh->calls->[-1], 'commit', 'a seed that works is committed' );

    for my $rollback_fails ( 0, 1 ) {
        my $failing = GPForum::Test::TransactionDbh->new(
            fail_on_rollback => $rollback_fails );
        my $error;
        try {
            _with_transaction( $failing, sub { croak 'insert failed' } );
        }
        catch ($caught) {
            $error = $caught;
        };
        my $when = $rollback_fails ? ' when its rollback fails' : q{};
        like(
            $error,
            qr/\Ainsert[ ]failed/msx,
            "a failed seed keeps its own error$when"
        );
        is( $failing->calls->[-1], 'rollback', 'and is rolled back' );
        ok( !grep( { $_ eq 'commit' } @{ $failing->calls } ),
            'and never committed' );
    }

    return;
}

# The private steps these two tests pin, called where they live: neither is
# reachable without a database.
sub _explain ( $dbh, $statement ) {
    return _private( q{QueryPlanEvidence}, q{_explain} )
      ->( $dbh, $statement, {} );
}

sub _with_transaction ( $dbh, $code ) {
    return _private( q{PerformanceSeed}, q{_with_transaction} )
      ->( $dbh, $code );
}

sub _private ( $command, $name ) {
    return "GPForum::Command::$command"->can($name)
      // croak "no GPForum::Command::${command}::$name";
}

# Runs the code with performance-seed's seed_profile recording the profiles
# it is asked for instead of seeding them.
sub _with_seed_recorded ( $seeded, $code ) {
    return with_replaced_subs(
        q{GPForum::Command::PerformanceSeed},
        {
            seed_profile =>
              sub ( $self, $profile ) { push @{$seeded}, $profile; return {} }
        },
        $code
    );
}

# A command run in process: its status, standard output and standard error,
# and what it died with when it did.
sub _run ( $command, @arguments ) {
    my ( $output, $errors ) = ( q{}, q{} );
    open my $stdout, '>', \$output or croak 'capture stdout';
    open my $stderr, '>', \$errors or croak 'capture stderr';
    my ( $status, $died ) =
      _status_of( $stdout, $stderr, $command, @arguments );
    close $stdout or croak 'close stdout';
    close $stderr or croak 'close stderr';

    return {
        died   => $died,
        errors => $errors,
        output => $output,
        status => $status,
    };
}

sub _status_of ( $stdout, $stderr, $command, @arguments ) {
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my ( $status, $died );
    try {
        $status = $command->run(@arguments);
    }
    catch ($error) {
        $died = "$error";
    };

    return ( $status, $died );
}

sub _terminated ($text) {
    return $text =~ /\n\z/msx ? $text : "$text\n";
}

1;
