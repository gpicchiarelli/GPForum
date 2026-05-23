package GPForum::Test::DenyPermissionGate;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub allowed {
    return 0;
}

1;
