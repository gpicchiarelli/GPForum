package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Command::Migrate;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 5;

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

throws_ok(
    sub {
        $command->run('--unknown');
    },
    qr/Usage/msx,
    'unknown migration command fails with usage'
);

1;
