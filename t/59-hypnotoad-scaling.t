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

use GPForum::Command::HypnotoadScaling;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;

const my $EXPECTED_TESTS => 22;

# The worker counts the dry run is asked for, and the text report's.
const my @WORKER_SET => ( 2, 4, 8 );
const my @TEXT_WORKER_SET => ( 2, 4 );

plan tests => $EXPECTED_TESTS;

my $command = GPForum::Command::HypnotoadScaling->new;

my $json_output   = q{};
my @run_arguments = (
    '--dry-run',    '--json',
    '--profile',    'hot-thread',
    '--worker-set', '2,4,8',
    '--iterations', '1',
    '--warmup',     '0',
    '--route',      '/categories',
    '--route',      '/t/018f1004-0001-7000-8000-000000000001',
);
my $dry_run_status;
open my $json_stdout, '>', \$json_output
  or croak 'failed to capture hypnotoad scaling JSON output';
{
    local *STDOUT = $json_stdout;
    $dry_run_status = $command->run(@run_arguments);
}
close $json_stdout or croak 'failed to close hypnotoad scaling JSON capture';
is( $dry_run_status, 0, 'hypnotoad scaling dry-run JSON command succeeds' );

my $json_report = decode_json($json_output);
is( $json_report->{mode}, 'hypnotoad-scaling', 'dry-run reports scaling mode' );
is( $json_report->{status}, 'dry-run',         'dry-run keeps dry-run status' );
is( $json_report->{dataset}{profile},
    'hot-thread', 'dry-run reports requested profile' );
is_deeply( $json_report->{workers},
    [@WORKER_SET], 'dry-run reports worker set' );
is(
    scalar @{ $json_report->{reports} },
    scalar @WORKER_SET,
    'dry-run includes one report per worker count'
);

for my $index ( 0 .. $#WORKER_SET ) {
    is( $json_report->{reports}[$index]{runtime}{workers_requested},
        $WORKER_SET[$index],
        "worker report $index uses $WORKER_SET[$index] workers" );
}
is(
    $json_report->{routes}[1],
    '/t/018f1004-0001-7000-8000-000000000001',
    'dry-run keeps real thread route'
);

my $text_report = $command->format_report(
    $command->scaling_report(
        {
            accepts              => 100,
            backlog              => 128,
            check                => 0,
            clients              => 100,
            compare_in_process   => 0,
            dry_run              => 1,
            format               => 'text',
            graceful             => 10,
            inactivity           => 30,
            iterations           => 2,
            keep_alive           => 5,
            profile              => 'small',
            regression_tolerance => 5,
            routes               => ['/search?q=performance'],
            seed                 => 0,
            warmup               => 1,
            worker_counts        => [@TEXT_WORKER_SET],
        }
    ),
    'text',
);

like( $text_report, qr/mode=hypnotoad-scaling/msx,
    'text report names scaling mode' );
like( $text_report, qr/workers=2,4/msx, 'text report includes worker set' );
like(
    $text_report,
    qr/worker_set [ ] workers=2/msx,
    'text report includes first worker set block'
);
like(
    $text_report,
    qr/worker_set [ ] workers=4/msx,
    'text report includes second worker set block'
);

is(
    _usage_status(
        sub {
            $command->run( '--dry-run', '--worker-set', '2,nope' );
        }
    ),
    $EXIT_USAGE,
    'hypnotoad scaling rejects invalid worker set'
);

is(
    _usage_status(
        sub {
            $command->run( '--dry-run', '--profile', 'massive' );
        }
    ),
    $EXIT_USAGE,
    'hypnotoad scaling rejects unknown profile'
);

is(
    _usage_status(
        sub {
            $command->run( '--dry-run', '--route', 'not-a-route' );
        }
    ),
    $EXIT_USAGE,
    'hypnotoad scaling rejects invalid route'
);

my $overall_status = GPForum::Command::HypnotoadScaling->can('_overall_status')
  // croak 'no _overall_status';
my $failing_report =
  $overall_status->( [ { status => 'ok' }, { status => 'fail' }, ] );
is( $failing_report, 'fail', 'overall scaling status detects failures' );

my $clean_report =
  $overall_status->( [ { status => 'ok' }, { status => 'ok' }, ] );
is( $clean_report, 'ok', 'overall scaling status passes clean reports' );

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
