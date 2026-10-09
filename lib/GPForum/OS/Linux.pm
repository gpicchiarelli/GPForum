# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::Linux;

use Mojo::Base 'GPForum::OS::Base', -signatures;
use v5.40;

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

# Debian and Ubuntu's postgresql package: a systemd service, and the server's
# superuser is the postgres system user.
sub postgresql_packaging {
    return {
        start           => 'sudo systemctl start postgresql',
        create_role     => 'sudo -u postgres createuser --pwprompt {user}',
        create_database =>
          'sudo -u postgres createdb --owner {user} {database}',
        set_password => q{sudo -u postgres psql -c '\password {user}'},
    };
}

sub postgresql_psql {
    return 'sudo -u postgres psql';
}

# The postgresql package runs the server as postgres, whom peer
# authentication on the local socket lets in as the role postgres.
sub postgresql_superuser {
    return {
        account => 'postgres',
        role    => 'postgres',
        sockets => [qw(/var/run/postgresql /run/postgresql)],
    };
}

# A system account with a group of its own, which cannot log in, at home in
# the code directory, as docs/DEPLOYMENT.md made it by hand.
sub service_account_commands ( $self, $user, $home ) {
    return [
        [
            'useradd',           '--system',
            '--user-group',      '--home-dir',
            $home,               '--shell',
            '/usr/sbin/nologin', $user,
        ]
    ];
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
