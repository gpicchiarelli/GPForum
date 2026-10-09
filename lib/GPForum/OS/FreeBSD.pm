# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::FreeBSD;

use Mojo::Base 'GPForum::OS::Base', -signatures;
use v5.40;

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

# deploy/freebsd's rc scripts read /usr/local/etc, as ports keep their
# configuration there.
sub environment_file {
    return '/usr/local/etc/gpforum/gpforum.env';
}

# The postgresql-server port: an rc.d service, and the server's superuser is
# the postgres system user.
sub postgresql_packaging {
    return {
        start           => 'sudo service postgresql start',
        create_role     => 'sudo -u postgres createuser --pwprompt {user}',
        create_database =>
          'sudo -u postgres createdb --owner {user} {database}',
        set_password => q{sudo -u postgres psql -c '\password {user}'},
    };
}

sub postgresql_psql {
    return 'sudo -u postgres psql';
}

# The postgresql-server port runs the server as postgres, with its socket in
# /tmp.
sub postgresql_superuser {
    return {
        account => 'postgres',
        role    => 'postgres',
        sockets => [qw(/tmp)],
    };
}

# pw makes a group of the same name with the account, which cannot log in.
sub service_account_commands ( $self, $user, $home ) {
    return [
        [
            'pw', 'useradd', $user, '-d', $home, '-s', '/usr/sbin/nologin',
            '-c', 'GPForum',
        ]
    ];
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
