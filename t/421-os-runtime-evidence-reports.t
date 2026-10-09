# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp    qw(croak);
use English qw(-no_match_vars);
use Const::Fast;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::OS::Base;
use GPForum::OS::RuntimeEvidence;
use GPForum::Runtime;
use GPForum::Test::OSResourceSnapshot;
use GPForum::Test::RuntimeEvidenceDbh;
use GPForum::Test::RuntimeEvidencePolicy;

our $VERSION = '0.001';

# The parts of the evidence report OS::RuntimeEvidence builds in place: the
# reuseport scan of Hypnotoad's listen URLs, the X-Accel-Redirect flag, an
# unsupported socket option, and the df and mount lines it parses. df and
# mount are scripts on PATH here, so the parsing is pinned whatever the host
# prints.

const my $EXECUTABLE => oct '0755';

subtest 'reuseport is configured when a listen URL asks for it' => sub {
    is(
        _hypnotoad( 'http://*:8080?reuse=1', 'http://*:8081' )
          ->{reuseport_configured},
        1,
        'reuse=1 as the first parameter'
    );
    is( _hypnotoad('http://*:8080?fd=3&reuse=1')->{reuseport_configured},
        1, 'reuse=1 after another parameter' );
    is(
        _hypnotoad( 'http://*:8080?reuse=0', 'http://*:8081' )
          ->{reuseport_configured},
        0,
        'reuse=0 and no parameter at all are not reuseport'
    );
    is( _hypnotoad()->{reuseport_configured}, 0, 'nor is no listen URL' );
};

subtest 'X-Accel-Redirect is implemented only with a prefix' => sub {
    is(
        _evidence( [], attachment_accel_redirect => '/protected' )
          ->{static_transfer}{x_accel_redirect_implemented},
        1,
        'a configured prefix emits the header'
    );
    is(
        _evidence( [], attachment_accel_redirect => q{} )
          ->{static_transfer}{x_accel_redirect_implemented},
        0,
        'an empty prefix does not'
    );
};

# Every host this runs on names the four options the report probes, so the
# branch for one it does not name is reached through the probe itself.
subtest 'a socket option the platform does not name is unsupported' => sub {
    is_deeply(
        GPForum::OS::RuntimeEvidence::_probe_socket_option(    ## no critic (Subroutines::ProtectPrivateSubs) -- Socket's constants cannot be withdrawn from a running test
            'imaginary', 'SOL_SOCKET', 'SO_GPFORUM_IMAGINARY'
        ),
        {
            status    => 'unavailable',
            name      => 'imaginary',
            supported => 0,
            set       => 0,
            verified  => 0,
        },
        'no socket is opened and nothing is claimed'
    );
};

subtest 'the df and mount lines are read column by column' => sub {
    my $bin = _fake_commands();
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    my $filesystem = _evidence( [] )->{filesystem};
    is_deeply(
        $filesystem->{df},
        {
            path             => '/tmp',
            available        => 1,
            filesystem       => '/dev/disk7',
            blocks           => '1000',
            used             => '400',
            available_blocks => '600',
            capacity         => '40%',
            mounted_on       => '/srv/gpforum',
        },
        'df -P: the last line, trimmed, in its six columns'
    );
    is_deeply(
        $filesystem->{mount},
        {
            available => 1,
            raw       => '/dev/disk7 on /srv/gpforum (tmpfs, local, nodev)',
            type      => 'tmpfs',
            options   => [qw(tmpfs local nodev)],
        },
        'mount: the line for that mount point, its type and its options'
    );
    is( $filesystem->{status}, 'active', 'which makes the filesystem active' );
};

subtest q{a df line short of six columns is no reading} => sub {
    my $bin =
      tempdir( q{gpforum-evidence-bin-XXXXXX}, TMPDIR => 1, CLEANUP => 1 );
    _write_script( "$bin/df", <<'DF' );
#!/bin/sh
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo '/dev/disk7 1000 400 600 40%'
DF
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    my $filesystem = _evidence( [] )->{filesystem};
    is_deeply(
        $filesystem->{df},
        { path => q{/tmp}, available => 0 },
        q{five columns are not read as six}
    );
    is( $filesystem->{status}, q{unavailable}, q{and nothing is mounted} );
};

done_testing();

sub _evidence ( $listen, %settings ) {
    my $config = GPForum::Config->new(%settings);

    return GPForum::OS::RuntimeEvidence->new(
        config  => $config,
        runtime => GPForum::Runtime->new(
            web_processes      => 1,
            worker_processes   => 1,
            realtime_processes => 1,
            os_profile         => GPForum::OS::Base->new(
                resource_probe => GPForum::Test::OSResourceSnapshot->new,
            ),
            os_feature_settings => $config->os_feature_settings,
        ),
        runtime_policy => GPForum::Test::RuntimeEvidencePolicy->new(
            report => {
                status    => q{ok},
                hypnotoad => { workers => 1, listen => $listen },
            }
        ),
        dbh          => GPForum::Test::RuntimeEvidenceDbh->new,
        tempfile_dir => '/tmp',
    )->report;
}

sub _hypnotoad (@listen) {
    return _evidence( \@listen )->{hypnotoad};
}

# A df whose last line has blanks around it and a mount that lists another
# file system first, then the one df named, with trailing blanks.
sub _fake_commands {
    my $bin =
      tempdir( 'gpforum-evidence-bin-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    _write_script( "$bin/df", <<'DF' );
#!/bin/sh
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo '  /dev/disk7   1000   400   600   40%   /srv/gpforum  '
DF
    _write_script( "$bin/mount", <<'MOUNT' );
#!/bin/sh
echo '/dev/disk1 on / (apfs, sealed, local)'
echo '/dev/disk7 on /srv/gpforum (tmpfs, local, nodev)  '
MOUNT

    return $bin;
}

sub _write_script ( $path, $body ) {
    open my $handle, '>', $path or croak "open $path: $OS_ERROR";
    print {$handle} $body or croak "write $path: $OS_ERROR";
    close $handle         or croak "close $path: $OS_ERROR";
    chmod $EXECUTABLE, $path or croak "chmod $path: $OS_ERROR";

    return;
}

1;
