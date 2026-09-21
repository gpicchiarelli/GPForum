package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::More;

use lib 'lib';

use GPForum::Command::DeadLetterCheck;
use GPForum::Service::Operations::DeadLetterCheck;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 17;

plan tests => $EXPECTED_TESTS;

my $service = GPForum::Service::Operations::DeadLetterCheck->new;

my $dry = $service->run( { mode => 'dry_run' } );
is( $dry->{status}, 'pass', 'dry-run passes' );
is( $dry->{mode},   'dry_run', 'dry-run mode set' );
ok( $dry->{secrets_redacted}, 'dry-run marks secrets_redacted' );
is( $dry->{private_beta_claimed}, 0, 'dry-run refuses private-beta claim' );

my $sim = $service->run( { mode => 'simulate' } );
is( $sim->{status}, 'pass', 'simulate passes permanent dead-letter path' );
is( $sim->{check},  'dead_letter_check', 'simulate sets check name' );
is( scalar @{ $sim->{steps} // [] }, 4, 'simulate records four staging steps' );
is_deeply(
    [ map { $_->{name} } @{ $sim->{steps} } ],
    [
        'force_permanent_failure',
        'assert_dead_letter_and_cancelled',
        'redispatch_selected_zero',
        'fresh_row_survives_retention_cutoff',
    ],
    'simulate covers docs/ops/dead-letters.md staging check'
);
ok( !( grep { $_->{status} ne 'pass' } @{ $sim->{steps} } ),
    'all simulate steps pass' );

my $command = GPForum::Command::DeadLetterCheck->new;
my $usage   = q{};
my $help_err = q{};
{
    open my $stdout, '>', \$usage or croak 'stdout';
    open my $stderr, '>', \$help_err or croak 'stderr';
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    is( $command->run('--help'), 0, 'help exits 0' );
    close $stdout or croak 'close stdout';
    close $stderr or croak 'close stderr';
}
like( $usage, qr/gpforum-dead-letter-check/msx, 'help names command' );
like( $usage, qr/private-beta/msx, 'help denies private-beta claim' );
unlike(
    $help_err,
    qr/Wide[ ]character/msx,
    'help avoids wide-character print warnings'
);

my $json = q{};
{
    open my $stdout, '>', \$json or croak 'stdout';
    local *STDOUT = $stdout;
    is( $command->run( '--json', '--simulate' ), 0, 'simulate json exits 0' );
    close $stdout or croak 'close stdout';
}
my $decoded = decode_json($json);
is( $decoded->{status}, 'pass', 'cli simulate status pass' );

my $stderr = q{};
{
    open my $err, '>', \$stderr or croak 'stderr';
    local *STDERR = $err;
    is( $command->run('--nope'), 2, 'unknown option exits usage' );
    close $err or croak 'close stderr';
}

my $human = $service->format_evidence( $sim, 'human' );
like(
    $human,
    qr/dead-letter-check [ ] status=pass/msx,
    'human evidence names status'
);

1;
