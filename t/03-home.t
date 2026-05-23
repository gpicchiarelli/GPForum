package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;
use Test::Mojo;

use lib 'lib';

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 5;
const my $HTTP_OK        => 200;
const my $ROOT_PATH      => q{/};

plan tests => $EXPECTED_TESTS;

my $test = Test::Mojo->new('GPForum');

$test->get_ok($ROOT_PATH);
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'GPForum' );
$test->text_like( 'p' => qr/Milestone [ ] zero/msx );
$test->content_like(qr/Web [ ] processes/msx);

1;
