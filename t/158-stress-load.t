package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Command::StressLoad;
use GPForum::Service::Operations::StressLoad;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 16;

plan tests => $EXPECTED_TESTS;

my $service  = GPForum::Service::Operations::StressLoad->new;
my $profiles = $service->profiles;

is( $profiles->{100}{concurrency},   100,   'profile 100 concurrency' );
is( $profiles->{500}{concurrency},   500,   'profile 500 concurrency' );
is( $profiles->{1000}{concurrency},  1_000, 'profile 1000 concurrency' );
is( $profiles->{smoke}{concurrency}, 4,     'smoke profile stays tiny' );

my $plan = $service->plan(
    {
        profile             => '100',
        base_url            => 'http://127.0.0.1:8080',
        routes              => ['/health/live'],
        concurrency         => undef,
        requests_per_client => undef,
    }
);
is( $plan->{total_requests}, 1_000,          'profile 100 total requests' );
is( $plan->{routes}[0],      '/health/live', 'custom route preserved' );

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
{
    open my $stdout, '>', \$dry_json or croak 'stdout';
    local *STDOUT = $stdout;
    is(
        $command->run(
            '--dry-run',  '--json',
            '--profile',  '500',
            '--base-url', 'http://127.0.0.1:9',
        ),
        0,
        'dry-run JSON exits 0'
    );
    close $stdout or croak 'close stdout';
}
my $dry = decode_json($dry_json);
is( $dry->{status},            'dry-run', 'dry-run status' );
is( $dry->{plan}{concurrency}, 500,       'dry-run concurrency from profile' );

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

1;
