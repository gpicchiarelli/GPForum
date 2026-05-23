package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 2;

plan tests => $EXPECTED_TESTS;

ok( -x 'script/architecture-check', 'architecture check script is executable' );

is( system('script/architecture-check'),
    0, 'architecture check passes controller boundary rules' );

1;
