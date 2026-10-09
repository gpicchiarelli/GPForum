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

use GPForum::Command::StressLoad;
use GPForum::Service::Operations::StressLoad;

our $VERSION = '0.001';

const my $EXPECTED_TESTS       => 20;
const my $SMOKE_CLIENTS        => 4;
const my $PROFILE_100_REQUESTS => 1_000;
const my $DRY_RUN_PROFILE      => '500';

plan tests => $EXPECTED_TESTS;

my $service  = GPForum::Service::Operations::StressLoad->new;
my $profiles = $service->profiles;

# Each numbered profile is named after the clients it runs.
for my $profile (qw(100 500 1000)) {
    is( $profiles->{$profile}{concurrency},
        $profile, "profile $profile concurrency" );
}
is( $profiles->{smoke}{concurrency},
    $SMOKE_CLIENTS, 'smoke profile stays tiny' );

my $plan = $service->plan(
    {
        profile             => '100',
        base_url            => 'http://127.0.0.1:8080',
        routes              => ['/health/live'],
        concurrency         => undef,
        requests_per_client => undef,
    }
);
is( $plan->{total_requests},
    $PROFILE_100_REQUESTS, 'profile 100 total requests' );
is( $plan->{routes}[0], '/health/live', 'custom route preserved' );

my $command = GPForum::Command::StressLoad->new;
my $usage   = q{};
{
    open my $stdout, '>', \$usage or croak 'stdout';
    local *STDOUT = $stdout;
    is( $command->run('--help'), 0, 'help exits 0' );
    close $stdout or croak 'close stdout';
}
like( $usage, qr/gpforum-stress-load/msx, 'help names the command' );
like(
    $usage,
    qr/100 [ ]\/ [ ]500 [ ]\/ [ ]1000/msx,
    'help names concurrency targets'
);

my $stderr = q{};
{
    open my $err, '>', \$stderr or croak 'stderr';
    local *STDERR = $err;
    is( $command->run( '--profile', 'nope' ), 2, 'bad profile exits usage' );
    close $err or croak 'close stderr';
}
like(
    $stderr,
    qr/Unsupported [ ] stress [ ] profile/msx,
    'bad profile message'
);

my $dry_json = q{};
my $dry_status;
{
    open my $stdout, '>', \$dry_json or croak 'stdout';
    local *STDOUT = $stdout;
    $dry_status =
      $command->run( '--dry-run', '--json', '--profile', $DRY_RUN_PROFILE,
        '--base-url', 'http://127.0.0.1:9', );
    close $stdout or croak 'close stdout';
}
is( $dry_status, 0, 'dry-run JSON exits 0' );
my $dry = decode_json($dry_json);
is( $dry->{status}, 'dry-run', 'dry-run status' );
is( $dry->{plan}{concurrency},
    $DRY_RUN_PROFILE, 'dry-run concurrency from profile' );
ok( $dry->{secrets_redacted}, 'stress evidence marks secrets_redacted' );
is( $dry->{private_beta_claimed},
    0, 'stress evidence refuses private-beta claim' );
ok(
    @{ $dry->{residual_gaps} // [] } >= 1,
    'stress evidence lists residual gaps'
);

my $human = $service->format_evidence( $dry, 'human' );
like(
    $human,
    qr/stress-load [ ] status=dry-run/msx,
    'human dry-run status line'
);

throws_ok(
    sub {
        $service->run(
            {
                dry_run  => 0,
                profile  => 'smoke',
                base_url => undef,
                routes   => [],
            }
        );
    },
    qr/base-url/msx,
    'live run without base-url croaks'
);

# The live-status rule, pinned without a live run.
## no critic (Subroutines::ProtectPrivateSubs) -- no public path reaches it offline
is(
    GPForum::Service::Operations::StressLoad::_check_status(
        { p95_ms => 10 },
        0,
        {
            max_error_rate_pct => 1,
            p95_limit_ms       => 2_000,
        },
        { check => 0 },
    ),
    'ok',
    'without --check live status is ok not pass'
);
## use critic

1;
