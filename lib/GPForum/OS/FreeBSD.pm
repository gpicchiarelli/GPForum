package GPForum::OS::FreeBSD;

use strict;
use warnings;

use Mojo::Base 'GPForum::OS::Base';

our $VERSION = '0.001';

has name => 'freebsd';

sub supports_reuseport {
    return 1;
}

sub supports_sendfile {
    return 1;
}

sub event_backend {
    return 'kqueue';
}

1;
