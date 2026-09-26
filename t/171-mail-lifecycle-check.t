# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json encode_json);
use Test::More;

use lib 'lib';

use GPForum::Command::MailLifecycleCheck;
use GPForum::Service::Operations::MailLifecycleCheck;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 15;

plan tests => $EXPECTED_TESTS;

my $service = GPForum::Service::Operations::MailLifecycleCheck->new;

my $dry = $service->run( { mode => 'dry_run' } );
is( $dry->{status}, 'pass',    'dry-run passes' );
is( $dry->{mode},   'dry_run', 'dry-run mode set' );
ok( $dry->{secrets_redacted}, 'dry-run marks secrets_redacted' );
is( $dry->{private_beta_claimed}, 0, 'dry-run refuses private-beta claim' );

my $sim = $service->run( { mode => 'simulate' } );
is( $sim->{status}, 'pass', 'simulate delivers all identity kinds' );
is( $sim->{check},  'mail_lifecycle_check', 'simulate sets check name' );
is( $sim->{delivery_count}, 3, 'simulate records three deliveries' );
ok( !( grep { $_->{status} ne 'pass' } @{ $sim->{steps} // [] } ),
    'all simulate steps pass' );
unlike(
    encode_json($sim),
    qr/mail-lifecycle-(?:reset|change|verify)-token/msx,
    'evidence scrubs probe tokens'
);

my $command = GPForum::Command::MailLifecycleCheck->new;
my $usage   = q{};
{
    open my $stdout, '>', \$usage or croak 'stdout';
    local *STDOUT = $stdout;
    is( $command->run('--help'), 0, 'help exits 0' );
    close $stdout or croak 'close stdout';
}
like( $usage, qr/gpforum-mail-lifecycle-check/msx, 'help names command' );
like( $usage, qr/private-beta/msx, 'help denies private-beta claim' );

my $json = q{};
{
    open my $stdout, '>', \$json or croak 'stdout';
    local *STDOUT = $stdout;
    is( $command->run( '--json', '--simulate' ), 0, 'simulate json exits 0' );
    close $stdout or croak 'close stdout';
}
my $decoded = decode_json($json);
is( $decoded->{status}, 'pass', 'cli simulate status pass' );

my $human = $service->format_evidence( $sim, 'human' );
like(
    $human,
    qr/mail-lifecycle-check [ ] status=pass/msx,
    'human evidence names status'
);

1;
