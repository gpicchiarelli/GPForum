# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::Darwin;

use Const::Fast;
use Mojo::Base 'GPForum::OS::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

const my @HOMEBREW_PREFIXES => qw(/opt/homebrew /usr/local);
const my $HOMEBREW_FILE     => 'etc/gpforum/gpforum.env';

# The ids a service account takes: below the login window's range, which
# starts at 500, and above the ones macOS gives its own daemons.
const my $FIRST_SERVICE_ID => 300;
const my $LAST_SERVICE_ID  => 499;

has name => 'darwin';

# The id the services' account and its group take: the highest under 500
# that no user and no group has, so both get the same one. The guide's 399
# was taken on the walkthrough's own Mac (com.apple.access_ssh). Undef when
# every one is taken; a test gives its own.
has account_id => sub {
    for my $id ( reverse $FIRST_SERVICE_ID .. $LAST_SERVICE_ID ) {
        return $id if !defined getpwuid $id && !defined getgrgid $id;
    }

    return undef;
};

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

# launchd has no environment file of its own: GPForum's lives under
# Homebrew's prefix, beside the services Homebrew runs, and bin/gpforum reads
# it for the service and for a command typed by hand (ADR 0120). The plists
# set only GPFORUM_ENV and the log; a sentence that sent an operator to the
# plist for any other setting sent them where nothing reads it. The prefix is
# HOMEBREW_PREFIX, else the one whose brew is installed, Apple silicon's
# first.
sub environment_file ($self) {
    my $prefix = $ENV{HOMEBREW_PREFIX};
    if ( !defined $prefix || !length $prefix ) {
        ($prefix) = grep { -x "$_/bin/brew" } @HOMEBREW_PREFIXES;
    }

    return ( $prefix // $HOMEBREW_PREFIXES[0] ) . "/$HOMEBREW_FILE";
}

# Homebrew's bin, the operator's own and on their PATH, as the README had
# them link gpforum into by hand; none when it is not theirs to write.
sub operator_bin ($self) {
    my $bin =
      $self->environment_file =~ s{ /etc/gpforum/gpforum[.]env \z}{/bin}rmsx;

    return -d $bin && -w $bin ? $bin : undef;
}

# Homebrew's postgresql@18: a `brew services` service run as the operator's
# own user, who is the server's superuser and is trusted locally.
sub postgresql_packaging {
    return {
        start           => 'brew services start postgresql@18',
        create_role     => 'createuser {user}',
        create_database => 'createdb --owner {user} {database}',
        set_password    => q{psql postgres -c '\password {user}'},
    };
}

sub event_backend {
    return 'kqueue';
}

# macOS has no useradd: its directory service takes a group and an account
# record by record, with dscl, as Apple's own daemons have them -- the same
# id for both, no password, no shell, hidden from the login window, at home
# in /var/empty. None when no id is free.
sub service_account_commands ( $self, $user, $home ) {
    my $id = $self->account_id;
    return [] if !defined $id;

    my @group = (
        [ 'PrimaryGroupID', $id ],
        [ 'RealName',       'GPForum' ],
        [ 'Password',       q{*} ],
    );
    my @account = (
        [ 'UniqueID',         $id ],
        [ 'PrimaryGroupID',   $id ],
        [ 'UserShell',        '/usr/bin/false' ],
        [ 'NFSHomeDirectory', '/var/empty' ],
        [ 'RealName',         'GPForum' ],
        [ 'Password',         q{*} ],
        [ 'IsHidden',         '1' ],
    );

    return [
        ( map { [ 'dscl', q{.}, '-create', "/Groups/$user", @{$_} ] } @group ),
        ( map { [ 'dscl', q{.}, '-create', "/Users/$user", @{$_} ] } @account ),
    ];
}

# Apple silicon mixes performance and efficiency cores, and a web worker on
# an efficiency core serves about half the pages one on a performance core
# does: on an M4 with four and six, 4 workers served 177 signed-in pages a
# second and 8 served 255 (docs/PERFORMANCE.md). For the automatic worker
# count a performance core is one worker and two efficiency cores are one.
# A Mac without performance levels, or whose sysctl does not answer, counts
# its CPUs as any other host.
sub worker_cpu_count ($self) {
    my $performance = $self->_perflevel_cpus(0);
    return $self->cpu_count if !defined $performance;

    my $efficiency = $self->_perflevel_cpus(1) // 0;

    return $performance + int $efficiency / 2;
}

sub _perflevel_cpus ( $self, $level ) {
    my $name     = "sysctl hw.perflevel$level.logicalcpu";
    my $detected = $self->cpu_probe->detect(
        [
            {
                name    => $name,
                type    => 'command',
                command =>
                  [ '/usr/sbin/sysctl', '-n', "hw.perflevel$level.logicalcpu" ],
            },
        ],
        [],
    );

    return $detected->{source} eq $name ? $detected->{count} : undef;
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
