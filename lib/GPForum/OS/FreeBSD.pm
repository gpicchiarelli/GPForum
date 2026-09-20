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

sub cpu_count_sources {
    return [
        {
            name    => 'sysctl hw.ncpu',
            type    => 'command',
            command => [ '/sbin/sysctl', '-n', 'hw.ncpu' ],
        },
        {
            name    => 'sysctl kern.smp.cpus',
            type    => 'command',
            command => [ '/sbin/sysctl', '-n', 'kern.smp.cpus' ],
        },
        { name => 'sysconf _SC_NPROCESSORS_ONLN', type => 'sysconf' },
    ];
}

1;
