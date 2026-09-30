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

# Homebrew: one clamav formula provides clamd and freshclam. Its clamd.conf
# ships only as a sample, with no socket; docs/ops/antivirus.md has the
# operator enable LocalSocket at the path below. `brew services` runs clamd
# (homebrew.mxcl.clamav); freshclam has no service of its own and is
# scheduled separately.
sub antivirus_packaging {
    return {
        packages => [qw(clamav)],
        services => [qw(homebrew.mxcl.clamav)],
        socket   => '/opt/homebrew/var/run/clamav/clamd.sock',
        install  => 'brew install clamav',
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
