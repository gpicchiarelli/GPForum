package GPForum::OS::Darwin;

use strict;
use warnings;

use Mojo::Base 'GPForum::OS::Base';

our $VERSION = '0.001';

has name => 'darwin';

sub supports_reuseport {
    return 1;
}

sub supports_sendfile {
    return 1;
}

sub event_backend {
    return 'kqueue';
}

sub cpu_count_sources {
    return [
        {
            name    => 'sysctl hw.logicalcpu',
            type    => 'command',
            command => [ '/usr/sbin/sysctl', '-n', 'hw.logicalcpu' ],
        },
        {
            name    => 'sysctl hw.ncpu',
            type    => 'command',
            command => [ '/usr/sbin/sysctl', '-n', 'hw.ncpu' ],
        },
        { name => 'sysconf _SC_NPROCESSORS_ONLN', type => 'sysconf' },
    ];
}

1;
