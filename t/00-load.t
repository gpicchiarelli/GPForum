package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';

our $VERSION = '0.001';

const my $TEST_COUNT => 4;

plan tests => $TEST_COUNT;

use_ok('GPForum');
use_ok('GPForum::Config');
use_ok('GPForum::Runtime');
use_ok('GPForum::Controller::Health');

1;
