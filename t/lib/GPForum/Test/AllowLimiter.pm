package GPForum::Test::AllowLimiter;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub check {
    return { ok => 1 };
}

1;
