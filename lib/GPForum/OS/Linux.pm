package GPForum::OS::Linux;

use strict;
use warnings;

use Mojo::Base 'GPForum::OS::Base';

our $VERSION = '0.001';

has name => 'linux';

sub supports_reuseport {
    return 1;
}

sub supports_sendfile {
    return 1;
}

sub event_backend {
    return 'epoll';
}

sub cpu_count_sources {
    return [
        {
            name    => 'nproc',
            type    => 'command',
            command => ['/usr/bin/nproc'],
        },
        {
            name    => 'nproc',
            type    => 'command',
            command => ['/bin/nproc'],
        },
        {
            name => '/sys/devices/system/cpu/online',
            type => 'cpu_list',
            path => '/sys/devices/system/cpu/online',
        },
        {
            name => '/proc/cpuinfo',
            type => 'cpuinfo',
            path => '/proc/cpuinfo',
        },
        { name => 'sysconf _SC_NPROCESSORS_ONLN', type => 'sysconf' },
    ];
}

sub cpu_count_limits {
    return [
        {
            name => 'cgroup v2 cpu.max',
            path => '/sys/fs/cgroup/cpu.max',
        },
    ];
}

1;
