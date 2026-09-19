package GPForum::Test::OSTinyLinux;

use strict;
use warnings;

use Mojo::Base 'GPForum::OS::Linux';

our $VERSION = '0.001';

sub cpu_count {
    return 1;
}

1;
