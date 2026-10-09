# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Service::Admin::Settings;

our $VERSION = '0.001';

# Three things the shipped service files did that an operator would only
# find out on the host (walkthrough 1, friction 16):
#
# - gpforum-unix-socket.service set
#   GPFORUM_RUNTIME_LISTEN=http+unix://%2Frun%2F..., and systemd reads % as
#   a specifier: %2 is none it knows, so it dropped the line and the service
#   listened on TCP, where nginx's unix-socket site found nothing.
# - The launchd plists ran every job as root.
# - The settings page said to restart gpforum after a change, and the outbox
#   worker, which sends with the mail settings, kept the old ones.

# The specifiers systemd.unit(5) lists; %% is a literal %.
my $SPECIFIER = qr/%[%aAbBCdEfgGhHiIjJlLmMnNopPqsStTuUvVwW]/msx;

subtest 'every % in a systemd unit is one systemd reads' => sub {

    # Comments are not read for specifiers.
    for my $unit ( sort glob 'deploy/systemd/*' ) {
        my $rest = join "\n", grep { !/\A \s* [#;]/msx }
          split /\n/msx, path($unit)->slurp =~ s/$SPECIFIER//grmsx;
        is_deeply( [ $rest =~ /(%.?)/gmsx ],
            [], "$unit has no % systemd would refuse" );
    }

    my ($listen) = path('deploy/systemd/gpforum-unix-socket.service')->slurp =~
      /^Environment=GPFORUM_RUNTIME_LISTEN=(\S+)$/msx;
    my $as_systemd_passes_it = $listen =~ s/%%/%/grmsx;
    is(
        $as_systemd_passes_it,
        'http+unix://%2Frun%2Fgpforum%2Fgpforum.sock',
        'the unix-socket unit passes the percent-encoded socket path'
    );
    is_deeply(
        GPForum::Config->from_environment(
            { GPFORUM_RUNTIME_LISTEN => $as_systemd_passes_it }
        )->runtime_listen_locations,
        ['http+unix://%2Frun%2Fgpforum%2Fgpforum.sock'],
        'a location GPForum listens on'
    );
    like(
        path('deploy/nginx/gpforum-unix-socket.conf')->slurp,
        qr{unix:/run/gpforum/gpforum[.]sock}msx,
        'the socket the unix-socket nginx site forwards to'
    );
    my $in_file = "GPFORUM_RUNTIME_LISTEN=$as_systemd_passes_it";
    like( path('docs/DEPLOYMENT.md')->slurp,
        qr/^\Q$in_file\E$/msx,
        'and the environment file form, with one %, as the guide gives it' );
};

subtest 'every launchd job runs as the service account' => sub {
    for my $plist ( sort glob 'deploy/launchd/*.plist' ) {
        my $text = path($plist)->slurp =~ s/<!-- .*? -->//grmsx;
        is( _plist_value( $text, 'UserName' ),
            'gpforum', "$plist runs as gpforum" );
        is( _plist_value( $text, 'GroupName' ), 'gpforum', 'in its group' );
        like(
            $text,
            qr{<string>/opt/gpforum/bin/gpforum</string>}msx,
            'through bin/gpforum, which reads the environment file'
        );
    }

    my $app = path('deploy/launchd/com.gpforum.app.plist')->slurp;
    is(
        _plist_value( $app, 'GPFORUM_RUNTIME_PID_FILE' ),
        '/opt/gpforum/var/hypnotoad.pid',
        q{Hypnotoad's pid file is under var/, which the account owns}
    );

    my ($macos) = path('docs/DEPLOYMENT.md')->slurp =~
      /^\#\# [ ] macOS [ ] With [ ] launchd \n (.*?) ^\#\# [ ]/msx;
    like(
        $macos,
        qr{^sudo [ ] gpforum [ ] setup$}msx,
        'setup makes the account, and var/ under the checkout'
    );

    # The plists log under Homebrew's prefix, which gpforum service print
    # puts in place of the template's /usr/local: /opt/homebrew on Apple
    # silicon.
    ok(
        scalar( () = $app =~ m{<string>/usr/local/var/log/gpforum/}gmsx ),
        'the template logs under the Intel prefix, which is rendered'
    );
    ok(
        index( $macos,
q{install -d -o gpforum -g gpforum -m 0750 "$(brew --prefix)/var/log/gpforum"}
        ) >= 0,
        q{and the guide makes the directory under Homebrew's prefix}
    );
};

subtest 'the settings page restarts what reads the settings' => sub {
    my $change = GPForum::Service::Admin::Settings->new(
        config      => GPForum::Config->new,
        environment => {},
    )->view->{change};

    my @long_running = map { path($_)->basename('.service') }
      grep {
        my $text = path($_)->slurp;
        $text =~ /^EnvironmentFile=/msx && $text !~ /^Type=oneshot$/msx
      }
      grep { !/unix-socket/msx } sort glob 'deploy/systemd/*.service';
    is_deeply(
        \@long_running,
        [qw(gpforum-outbox gpforum)],
        'two services read the environment file and keep running'
    );
    is(
        $change->{restart},
        'systemctl restart gpforum gpforum-outbox',
        'the page restarts both'
    );
    is(
        $change->{freebsd_restart},
        'service gpforum restart && service gpforum_outbox restart',
        'and says how on FreeBSD'
    );
    for my $script (qw(gpforum gpforum_outbox)) {
        ok( -e "deploy/freebsd/$script",
            "deploy/freebsd/$script is the rc script it names" );
    }
};

done_testing();

# The string a plist gives a key, or undef.
sub _plist_value ( $text, $key ) {
    my ($value) = $text =~ m{<key>\Q$key\E</key> \s* <string>([^<]*)<}msx;

    return $value;
}

1;
