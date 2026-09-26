# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::Linux;

use strict;
use warnings;

use Mojo::Base 'GPForum::OS::Base', -signatures;

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

# Debian and Ubuntu's clamav-daemon: LocalSocket /var/run/clamav/clamd.ctl
# (also Debian's ClamAV::Client default). Other distributions package clamd
# with other paths; set GPFORUM_ANTIVIRUS_SOCKET there.
sub antivirus_packaging {
    return {
        packages => [qw(clamav-daemon clamav-freshclam)],
        services => [qw(clamav-daemon clamav-freshclam)],
        socket   => '/var/run/clamav/clamd.ctl',
        install  => 'apt install clamav-daemon clamav-freshclam',
    };
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
