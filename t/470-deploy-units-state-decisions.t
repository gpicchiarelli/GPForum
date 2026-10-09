# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::File qw(path);
use Mojo::JSON qw(encode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum;
use GPForum::Config;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;
use GPForum::Test::OSTinyLinux;

our $VERSION = '0.001';

# What an operator's env file holds in production, so the configuration a unit
# builds can be read without the secrets it would refuse to start without.
const my %ENV_FILE => (
    GPFORUM_SESSION_SECRET  => 'a' x 64,
    GPFORUM_METRICS_TOKEN   => 'b' x 32,
    GPFORUM_GLIFISTORE_URL  => 'tcp://127.0.0.1:7379',
    GPFORUM_PUBLIC_BASE_URL => 'https://forum.gpforum.test',
    GPFORUM_MAIL_FROM       => 'forum@forum.gpforum.test',
);

# The walkthrough (docs/ops/evidence/2026-10-07-operator-walkthrough, section
# 2.3) found 23 Environment= lines in each web unit and plist restating
# GPForum::Config's defaults, and MOJO_MODE, which Bootstrap::Core overwrites
# with GPFORUM_ENV. A default changed in Config.pm stayed behind in every
# installed unit. Each setting a service file makes must now change the
# configuration it starts with.
subtest 'every setting a systemd unit makes is a decision' => sub {
    for my $unit ( sort glob 'deploy/systemd/*.service' ) {
        _decisions_only( $unit, _unit_environment( path($unit)->slurp ) );
    }
};

subtest 'every setting a launchd plist makes is a decision' => sub {
    for my $plist ( sort glob 'deploy/launchd/*.plist' ) {
        _decisions_only( $plist, _plist_environment( path($plist)->slurp ) );
    }
};

subtest 'nothing sets MOJO_MODE, which GPFORUM_ENV overrides' => sub {
    for my $file ( sort grep { -f } glob 'deploy/*/*' ) {
        unlike( path($file)->slurp, qr/MOJO_MODE/msx, "$file" );
    }
};

# PIDFile= used to name /opt/gpforum/hypnotoad.pid, which had to agree with
# GPFORUM_RUNTIME_PID_FILE and the working directory: change either and
# systemd tracked a file nobody wrote. The pid file now follows from
# RuntimeDirectory=, which systemd passes on as RUNTIME_DIRECTORY.
subtest 'the pid file follows from the runtime directory' => sub {
    my $default = GPForum::Config->new->runtime_pid_file;
    is(
        _policy( runtime_directory => '/run/gpforum' )
          ->hypnotoad_config->{pid_file},
        "/run/gpforum/$default",
        'a relative pid file goes into the runtime directory'
    );
    is(
        _policy( runtime_directory => '/run/gpforum:/run/other' )
          ->hypnotoad_config->{pid_file},
        "/run/gpforum/$default",
        'the first one, when the unit names several'
    );
    is( _policy( runtime_directory => undef )->hypnotoad_config->{pid_file},
        $default, 'and stays relative to the working directory without one' );
    is(
        _policy(
            runtime_directory => '/run/gpforum',
            pid_file          => '/var/tmp/gpforum.pid'
        )->hypnotoad_config->{pid_file},
        '/var/tmp/gpforum.pid',
        'an absolute GPFORUM_RUNTIME_PID_FILE is kept as it is'
    );
    {
        local $ENV{RUNTIME_DIRECTORY} = '/run/gpforum';
        is(
            GPForum::OS::RuntimePolicy->new(
                config  => GPForum::Config->new,
                runtime => _runtime(),
            )->hypnotoad_config->{pid_file},
            "/run/gpforum/$default",
            'read from RUNTIME_DIRECTORY, as systemd sets it'
        );
    }

    for my $unit ( sort glob 'deploy/systemd/*.service' ) {
        my $text = path($unit)->slurp;
        my ($pid_file) = $text =~ /^PIDFile=(\S+)$/msx;
        next if !defined $pid_file;
        my ($directory) = $text =~ /^RuntimeDirectory=(\S+)$/msx;
        is(
            $pid_file,
            "/run/@{[ $directory // 'none' ]}/$default",
            "$unit tracks the pid file its runtime directory holds"
        );
    }
};

# The units shipped before this release set MOJO_MODE and tracked
# PIDFile=/opt/gpforum/hypnotoad.pid. One still installed after the code is
# upgraded would wait for a pid file Hypnotoad no longer writes there, and
# systemd would fail the start: under it the pid file stays where it was, and
# the start says to copy the unit again.
subtest 'a unit from before this release still starts' => sub {
    my $default = GPForum::Config->new->runtime_pid_file;
    my $old     = _policy(
        runtime_directory => '/run/gpforum',
        mojo_mode         => 'production'
    );
    ok( $old->outdated_unit,
        'MOJO_MODE under a runtime directory is the old unit' );
    is( $old->hypnotoad_config->{pid_file},
        $default, 'which keeps the pid file in the working directory' );
    ok( !_policy( runtime_directory => '/run/gpforum' )->outdated_unit,
        'the current unit is not' );
    ok( !_policy( mojo_mode => 'production' )->outdated_unit,
        'nor MOJO_MODE outside systemd' );

    my $log = Mojo::File::tempfile;
    {
        local $ENV{RUNTIME_DIRECTORY} = '/run/gpforum';
        local $ENV{MOJO_MODE}         = 'production';
        local $ENV{GPFORUM_LOG_PATH}  = "$log";
        local $ENV{LC_ALL}            = 'C';
        GPForum->new;
    }
    my $logged = $log->slurp;
    like(
        $logged,
        qr/\[warn\] [ ] The [ ] installed [ ] systemd [ ] unit/msx,
        'and the start logs what to do'
    );
    like(
        $logged,
        qr{copy [ ] the [ ] units [ ] in [ ] deploy/systemd/}msx,
        'naming the files to copy'
    );
};

done_testing();

# Each setting in a service file, taken away on its own, must leave a
# different configuration behind.
sub _decisions_only ( $file, %settings ) {
    my $with = _configuration( %ENV_FILE, %settings );
    for my $name ( sort keys %settings ) {
        my %without = %settings;
        delete $without{$name};
        my $other = _configuration( %ENV_FILE, %without );
        isnt( $other, $with,
            "$file: $name=$settings{$name} is not GPForum::Config's default" );
    }

    return;
}

# The configuration as text: Mojo::JSON sorts the keys, so two equal
# configurations print the same.
sub _configuration (%environment) {
    return encode_json(
        { %{ GPForum::Config->from_environment( \%environment ) } } );
}

# The assignments as systemd passes them on: %% is one %.
sub _unit_environment ($text) {
    my @settings;
    for my $line ( split /\n/msx, $text ) {
        my ( $name, $value ) = $line =~ /\A Environment= ([^=]+) = (.*) \z/msx;
        next if !defined $name;
        push @settings, $name, $value =~ s/%%/%/grmsx;
    }

    return @settings;
}

sub _plist_environment ($text) {
    my ($dictionary) =
      $text =~ m{<key>EnvironmentVariables</key> \s* <dict> (.*?) </dict>}msx;
    $dictionary //= q{};
    $dictionary =~ s/<!-- .*? -->//gmsx;

    return $dictionary =~
      m{<key>([^<]+)</key> \s* <string>([^<]*)</string>}gmsx;
}

sub _policy (%options) {
    my %settings =
      defined $options{pid_file}
      ? ( runtime_pid_file => $options{pid_file} )
      : ();

    return GPForum::OS::RuntimePolicy->new(
        config            => GPForum::Config->new(%settings),
        runtime           => _runtime(),
        runtime_directory => $options{runtime_directory},
        mojo_mode         => $options{mojo_mode},
    );
}

sub _runtime {
    return GPForum::Runtime->new(
        web_processes => 1,
        os_profile    => GPForum::Test::OSTinyLinux->new,
    );
}

1;
