# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::FreeBSD;

use strict;
use warnings;

use Mojo::Base 'GPForum::OS::Base', -signatures;

our $VERSION = '0.001';

has name => 'freebsd';

sub supports_reuseport {
    return 1;
}

sub supports_sendfile {
    return 1;
}

# security/clamav: the port rewrites clamd.conf to
# LocalSocket /var/run/clamav/clamd.sock and installs the clamav_clamd and
# clamav_freshclam rc.d services.
sub antivirus_packaging {
    return {
        packages => [qw(clamav)],
        services => [qw(clamav_clamd clamav_freshclam)],
        socket   => '/var/run/clamav/clamd.sock',
        install  => 'pkg install clamav',
    };
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
