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
use GPForum::Test::AppliedRunner;
use GPForum::Test::WindowLifecycle;

our $VERSION = '0.001';

const my $EXIT_FAILURE => 1;
const my $EXIT_USAGE   => 2;

const my $EXPECTED_TESTS => 38;

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

my $command = GPForum::Command::Migrate->new;
my $output  = q{};

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
        "applied 049 rolling partitions c0ffee\n"
          . 'partition created audit_log_2026_11'
          . " range=2026-11-01T00:00:00Z..2026-12-01T00:00:00Z\n",
        'each partition created is a line after the migrations'
    );

    my $quiet = _apply( GPForum::Test::WindowLifecycle->new, [], '--apply' );
    is( $quiet->{status}, 0,   'a second --apply is 0' );
    is( $quiet->{output}, q{}, 'and prints nothing when nothing was done' );

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

    _assert_window_failures();

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
        qr/\Aapplied [ ] 049/msx,
        'while the migrations it applied are still listed'
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

sub _apply {
    my ( $lifecycle, $applied, @arguments ) = @_;

    my $migrate = GPForum::Command::Migrate->new(
        partition_lifecycle => $lifecycle,
        runner => GPForum::Test::AppliedRunner->new( applied => $applied ),
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
