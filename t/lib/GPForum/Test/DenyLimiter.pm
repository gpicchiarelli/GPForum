package GPForum::Test::DenyLimiter;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub check {
    return { ok => 0 };
}

1;
