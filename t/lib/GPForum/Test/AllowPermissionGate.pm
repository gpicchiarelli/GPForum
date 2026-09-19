package GPForum::Test::AllowPermissionGate;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub allowed {
    return 1;
}

1;
