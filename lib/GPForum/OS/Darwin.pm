# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::Darwin;

use strict;
use warnings;

use Mojo::Base 'GPForum::OS::Base', -signatures;

our $VERSION = '0.001';

has name => 'darwin';

sub supports_reuseport {
    return 1;
}

sub supports_sendfile {
    return 1;
}

# MacPorts: clamav provides clamd, clamav-server its launchd items and a
# clamd.conf with LocalSocket /opt/local/var/run/clamav/clamd.socket. Its
# default variants add a whole-disk scheduled scan that moves what it finds and
# third-party signatures; GPForum needs neither, so they are turned off.
sub antivirus_packaging {
    return {
        packages => [qw(clamav clamav-server)],
        services => [qw(org.macports.clamd org.macports.freshclam)],
        socket   => '/opt/local/var/run/clamav/clamd.socket',
        install  =>
'port install clamav clamav-server -scan_schedule_access -sanesecurity',
    };
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
