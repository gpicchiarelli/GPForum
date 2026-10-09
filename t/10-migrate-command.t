# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Migrate;
use GPForum::Migration::Runner;
use GPForum::Test::AppliedRunner;
use GPForum::Test::BudgetSync;
use GPForum::Test::MigrationSchema;
use GPForum::Test::WindowLifecycle;

our $VERSION = '0.001';

const my $EXIT_FAILURE => 1;
const my $EXIT_USAGE   => 2;

# The endpoints GPForum::Test::BudgetSync says it synced.
const my $BUDGETS => 25;

const my $EXPECTED_TESTS => 53;

const my %MIGRATION => (
    checksum          => 'c0ffee',
    description       => 'rolling partitions',
    execution_time_ms => 1,
    version           => '049',
);
const my %NOVEMBER => (
    default_partition => 'audit_log_default',
    partition_name    => 'audit_log_2026_11',
    range_end         => '2026-12-01T00:00:00Z',
    range_start       => '2026-11-01T00:00:00Z',
    table_name        => 'audit_log',
);

plan tests => $EXPECTED_TESTS;

# --plan asks the database what is pending: here, one that has applied
# nothing, so every migration is.
my $command = GPForum::Command::Migrate->new(
    runner => GPForum::Migration::Runner->new(
        schema => GPForum::Test::MigrationSchema->new
    )
);
my $output = q{};

open my $stdout, '>', \$output
  or croak 'failed to capture stdout';

{
    local *STDOUT = $stdout;

    is( $command->run('--plan'), 0, 'plan command returns success' );
}
close $stdout
  or croak 'failed to close stdout capture';

like(
    $output,
    qr/\A \d+ [ ] migrations [ ] to [ ] apply, [ ] 001 [ ] to [ ] \d+:$/msx,
    'plan command says how many are pending, from which to which'
);
like(
    $output,
    qr/^Next: [ ] gpforum [ ] migrate$/msx,
    'and that gpforum migrate applies them'
);
like(
    $output,
    qr/001 [ ] core [ ] identity/msx,
    'plan command prints first migration'
);
like(
    $output,
    qr/004 [ ] platform [ ] governance/msx,
    'plan command prints governance migration'
);
like(
    $output,
    qr/005 [ ] notifications [ ] subscriptions/msx,
    'plan command prints notifications migration'
);
like(
    $output,
    qr/006 [ ] attachments/msx,
    'plan command prints attachments migration'
);
like(
    $output,
    qr/007 [ ] advanced [ ] community/msx,
    'plan command prints advanced community migration'
);
like(
    $output,
    qr/008 [ ] moderation [ ] review/msx,
    'plan command prints moderation review migration'
);
like(
    $output,
    qr/009 [ ] admin [ ] authorization/msx,
    'plan command prints admin authorization migration'
);
like(
    $output,
    qr/010 [ ] import [ ] export/msx,
    'plan command prints import export migration'
);
like( $output, qr/011 [ ] plugins/msx,
    'plan command prints plugins migration' );

is(
    _usage_status(
        sub {
            $command->run('--unknown');
        }
    ),
    $EXIT_USAGE,
    'unknown migration command fails with usage'
);

_assert_partition_window();

# ADR 0113: --apply ensures the partition window once the migrations are in,
# so a fresh install has its current month before the first write and every
# deploy refreshes the window.
sub _assert_partition_window {
    local $ENV{GPFORUM_ENV} = 'development';
    my $lifecycle = GPForum::Test::WindowLifecycle->new;
    $lifecycle->result->{created} = [ {%NOVEMBER} ];
    my $first = _apply( $lifecycle, [ {%MIGRATION} ], '--apply' );
    is( $first->{status}, 0, '--apply with the window ensured is 0' );
    is_deeply(
        $lifecycle->calls,
        [ { apply => 1 } ],
        'the window is ensured, applying, with the default lookahead'
    );
    is(
        $first->{output},
        'Applied migration 049, rolling partitions;'
          . " created 1 monthly partition.\n"
          . "Next: gpforum start --foreground\n",
        'one line says what it did, and the next line what to do'
    );

    my $quiet = _apply( GPForum::Test::WindowLifecycle->new, [], '--apply' );
    is( $quiet->{status}, 0, 'a second --apply is 0' );
    like(
        $quiet->{output},
        qr/\A Schema [ ] is [ ] current [ ] [(] \d+ [)][.]\n \z/msx,
        'and says the schema is current, without a next step'
    );
    my $silent =
      _apply( GPForum::Test::WindowLifecycle->new, [], '--apply', '--quiet' );
    is( $silent->{status}, 0,   '--quiet is 0' );
    is( $silent->{output}, q{}, 'and prints nothing, for scripts' );

    my $skipping = GPForum::Test::WindowLifecycle->new;
    $skipping->result->{skipped} = 1;
    my $skipped = _apply( $skipping, [], '--apply', '--json' );
    is( $skipped->{status}, 0,
        'another run holding the maintenance lock is no failure' );
    is( decode_json( $skipped->{output} )->{partitions}{skipped},
        1, 'and the document says it was skipped' );

    my $untouched = GPForum::Test::WindowLifecycle->new;
    my $without =
      _apply( $untouched, [ {%MIGRATION} ], '--apply', '--no-partitions' );
    is( $without->{status}, 0, '--no-partitions is 0' );
    is_deeply( $untouched->calls, [], 'and leaves the window alone' );
    my $bare = decode_json(
        _apply( $untouched, [], '--apply', '--no-partitions', '--json' )
          ->{output} );
    ok( !exists $bare->{partitions}, 'its document has no partitions' );

    is( _apply( $untouched, [], '--plan', '--no-partitions' )->{status},
        $EXIT_USAGE, '--no-partitions without --apply is misuse' );

    my $json_window = GPForum::Test::WindowLifecycle->new;
    $json_window->result->{created} = [ {%NOVEMBER} ];
    my $document = decode_json(
        _apply( $json_window, [ {%MIGRATION} ], '--apply', '--json' )->{output}
    );
    is( $document->{status},             'ok', '--json says ok' );
    is( $document->{partitions}{status}, 'ok', 'and so does its window' );
    is_deeply(
        [ map { $_->{partition_name} } @{ $document->{partitions}{created} } ],
        ['audit_log_2026_11'],
        'listing the partitions it created'
    );
    is( $document->{budgets}{synced}, $BUDGETS, 'and the budgets it synced' );

    _assert_window_failures();
    _assert_budgets();
    _assert_next_steps();

    return;
}

# The query budgets follow the migrations, so a fresh install's readiness
# report is ok without a step of its own; a sync that fails, fails the run.
sub _assert_budgets {
    my $budgets = GPForum::Test::BudgetSync->new( written => 3 );
    my $synced  = _apply( GPForum::Test::WindowLifecycle->new,
        [], '--apply', { query_budget => $budgets } );
    is( scalar @{ $budgets->calls }, 1, 'the budgets are synced once' );
    like(
        $synced->{output},
qr/; [ ] synced [ ] the [ ] query [ ] budgets [ ] [(]3 [ ] changed[)][.]/msx,
        'and the line says how many changed'
    );

    my $broken =
      GPForum::Test::BudgetSync->new( failure => 'permission denied' );
    my $failed = _apply(
        GPForum::Test::WindowLifecycle->new,
        [ {%MIGRATION} ],
        '--apply', { query_budget => $broken }
    );
    is( $failed->{status}, $EXIT_FAILURE, 'a sync that fails is 1' );
    like(
        $failed->{errors},
        qr{could [ ] not [ ] be [ ] synced: [ ] permission [ ] denied}msx,
        'with its reason'
    );
    like( $failed->{errors}, qr{docs/PERFORMANCE[.]md}msx, 'and the runbook' );
    like(
        $failed->{output},
        qr/\A Applied [ ] migration [ ] 049/msx,
        'while the migrations it applied are still said'
    );

    return;
}

# What comes after: the owner on an install without one, a restart where a
# service runs the old schema.
sub _assert_next_steps {
    my $ownerless = _apply( GPForum::Test::WindowLifecycle->new,
        [], '--apply', { owner_check => sub { return 0; } } );
    like(
        $ownerless->{output},
        qr{^Next: [ ] make [ ] the [ ] forum's [ ] owner}msx,
        'an install without an owner is told to make one'
    );

    local $ENV{GPFORUM_ENV} = 'production';
    my $served = _apply(
        GPForum::Test::WindowLifecycle->new,
        [ {%MIGRATION} ],
        '--apply', { owner_check => sub { return 1; } }
    );
    like(
        $served->{output},
        qr{^Next: [ ] restart [ ] the [ ] service [ ] on [ ] the [ ] new}msx,
        'a production schema change is followed by a restart'
    );

    my $dry = _captured(
        sub {
            return GPForum::Command::Migrate->new(
                runner => GPForum::Migration::Runner->new(
                    schema => GPForum::Test::MigrationSchema->new
                )
            )->run('--dry-run');
        }
    );
    is( $dry->{status}, 0, '--dry-run is --plan' );
    like(
        $dry->{output},
        qr/migrations [ ] to [ ] apply/msx,
        'and says what is pending'
    );

    return;
}

# The migrations have committed; a window left incomplete still fails the
# command, loudly, pointing at the runbook.
sub _assert_window_failures {
    my $blocked = GPForum::Test::WindowLifecycle->new;
    $blocked->result->{ok} = 0;
    my %conflict = (
        %NOVEMBER,
        conflicting_rows => 2,
        error            => 'default_partition_overlap',
        message          => 'rows already in audit_log_default overlap',
        remediation      => ['BEGIN;'],
    );
    $blocked->result->{conflicts} = [ \%conflict ];
    my $conflict = _apply( $blocked, [ {%MIGRATION} ], '--apply' );
    is( $conflict->{status}, $EXIT_FAILURE, 'a conflict in the window is 1' );
    like(
        $conflict->{errors},
        qr/audit_log_2026_11: [ ] rows [ ] already/msx,
        'naming the partition on stderr'
    );
    like(
        $conflict->{errors},
        qr{docs/ops/partition-maintenance[.]md}msx,
        'and the runbook'
    );
    like(
        $conflict->{output},
        qr/\AApplied [ ] migration [ ] 049/msx,
        'while the migrations it applied are still said'
    );

    my $json = _apply( $blocked, [ {%MIGRATION} ], '--apply', '--json' );
    is( $json->{status}, $EXIT_FAILURE, 'under --json too' );
    my $document = decode_json( $json->{output} );
    is( $document->{status}, 'fail', 'which says fail' );
    is_deeply( [ map { $_->{version} } @{ $document->{applied} } ],
        ['049'], 'with the migrations applied all the same' );
    is( $document->{partitions}{conflicts}[0]{partition_name},
        'audit_log_2026_11', 'the conflict' );
    like(
        $document->{error},
        qr/partition-maintenance[.]md/msx,
        'and the runbook in its error'
    );

    my $broken = GPForum::Test::WindowLifecycle->new(
        failure => 'partition lifecycle: lookahead_months must be' );
    my $died = _apply( $broken, [], '--apply' );
    is( $died->{status}, $EXIT_FAILURE, 'a lifecycle that dies is 1' );
    like(
        $died->{errors},
        qr/could [ ] not [ ] be [ ] ensured: [ ] partition [ ] lifecycle/msx,
        'with its reason'
    );
    unlike(
        $died->{errors},
        qr/[ ] line [ ] \d+/msx,
        'without the code location'
    );

    return;
}

# A run with the window and the budgets given; a last hash reference
# argument holds the command's other attributes.
sub _apply {
    my ( $lifecycle, $applied, @arguments ) = @_;

    my %attributes = ref $arguments[-1] eq 'HASH' ? %{ pop @arguments } : ();
    my $migrate    = GPForum::Command::Migrate->new(
        partition_lifecycle => $lifecycle,
        query_budget        => GPForum::Test::BudgetSync->new,
        runner => GPForum::Test::AppliedRunner->new( applied => $applied ),
        %attributes,
    );

    return _captured( sub { return $migrate->run(@arguments) } );
}

sub _captured {
    my ($code) = @_;

    my ( $captured, $errors, $status ) = ( q{}, q{} );
    open my $stdout_capture, '>', \$captured or croak 'capture stdout';
    open my $stderr_capture, '>', \$errors   or croak 'capture stderr';
    {
        local *STDOUT = $stdout_capture;
        local *STDERR = $stderr_capture;
        $status = $code->();
    }
    close $stdout_capture or croak 'close stdout';
    close $stderr_capture or croak 'close stderr';

    return { errors => $errors, output => $captured, status => $status };
}

# A usage error is no longer an exception: the command returns the documented
# exit status and prints the usage text to stderr, which is what an operator
# and a wrapper script can both act on.
sub _usage_status {
    my ($code) = @_;

    my $errors = q{};
    open my $capture, '>', \$errors or croak 'capture stderr';
    my $status;
    {
        local *STDERR = $capture;
        $status = $code->();
    }
    close $capture or croak 'close stderr';
    like( $errors, qr/Usage/msx, 'the usage text goes to stderr' );

    return $status;
}

1;
