# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::File qw(path);
use Mojolicious::Routes::Match;
use Test::More;

use lib 'lib';

use GPForum;
use GPForum::CLI::FrontDoor::Launcher;
use GPForum::Config;
use GPForum::OS;
use GPForum::Service::Attachment::Validator;
use GPForum::Service::Operations::ServiceFiles;

our $VERSION = '0.001';

const my $MEBIBYTE => 1_024 * 1_024;

# The code directory every shipped service file and proxy configuration
# names.
const my $HOME => '/opt/gpforum';

# The walkthrough (docs/ops/evidence/2026-10-07-operator-walkthrough, section
# 1.1) followed the guide on a bare Debian host and found it disagreeing with
# the files it ships: the outbox worker never enabled, nginx refusing uploads
# the application accepts, an X-Accel-Redirect it said did not exist, /metrics
# open behind Caddy, and the service user, the code's owner and the
# certificate left to guesswork. Each check names one of them.

my $guide   = path('docs/DEPLOYMENT.md')->slurp;
my $install = _section( $guide, 'Install on Debian or Ubuntu' );
my $readme  = path('README.md')->slurp;

subtest 'the install enables the outbox worker beside the web unit' => sub {
    like(
        $install,
qr/systemctl [ ] enable [ ] --now [ ] gpforum [ ] gpforum-outbox [ ]/msx,
        'systemctl enable names gpforum-outbox'
    );
    my ($directory) =
      $install =~ m{^ [ ]* sudo [ ] gpforum [ ] service [ ] print [ ] --to [ ]
                    (\S+) $}msx;
    ok( defined $directory,
        'the install prints the units it enables, for this host' );
    is( $directory, '/etc/systemd/system',
        'into the directory systemd reads them from' );
    my @printed = map { $_->{template} }
      @{ GPForum::Service::Operations::ServiceFiles->new->files('systemd') };
    for my $unit (@printed) {
        ok( -f $unit, "$unit exists" );
    }
    ok( ( grep { $_ eq 'deploy/systemd/gpforum-outbox.service' } @printed ),
        'the outbox unit among them' );
};

subtest 'every supervisor ships an outbox worker' => sub {
    my $rc = path('deploy/freebsd/gpforum_outbox')->slurp;
    like(
        $rc,
        qr/bin\/gpforum [ ] --env-file [ ] \S+ [ ] outbox [ ] --loop/msx,
        'FreeBSD: an rc script looping the dispatcher through the front door'
    );
    _has(
        $rc,
        'gpforum_env_file:="/usr/local/etc/gpforum/gpforum.env"',
        'reading the environment file the web rc script reads'
    );
    is( system( 'sh', '-n', 'deploy/freebsd/gpforum_outbox' ),
        0, 'which parses as sh' );
    ok( -x 'deploy/freebsd/gpforum_outbox', 'and is executable' );

    my $plist     = path('deploy/launchd/com.gpforum.outbox.plist')->slurp;
    my @arguments = $plist =~ m{<string>([^<]*)</string>}gmsx;
    ok(
        (
            grep {
                     $arguments[$_] =~ m{/bin/gpforum\z}msx
                  && ( $arguments[ $_ + 1 ] // q{} ) eq 'outbox'
                  && ( $arguments[ $_ + 2 ] // q{} ) eq '--loop'
            } 0 .. $#arguments
        ),
        'launchd: a plist looping the dispatcher through the front door,'
          . ' which reads the environment file launchd has none of'
    );
    like(
        $plist,
        qr{<key>KeepAlive</key> \s* <true/>}msx,
        'kept alive like the web plist'
    );
    like(
        _section( $guide, 'FreeBSD With rc.d' ),
        qr/gpforum_outbox_enable=YES/msx,
        'the guide enables it on FreeBSD'
    );
    like(
        _section( $guide, 'macOS With launchd' ),
        qr/com[.]gpforum[.]outbox[.]plist/msx,
        'and names it for launchd'
    );
};

subtest 'nginx takes an upload as large as the application accepts' => sub {
    my $largest = GPForum::Service::Attachment::Validator->max_bytes;
    for my $file (
        qw(deploy/nginx/gpforum.conf deploy/nginx/gpforum-unix-socket.conf))
    {
        my ($limit) =
          path($file)->slurp =~ /client_max_body_size \s+ (\d+)m;/msx;
        ok(
            defined $limit && $limit * $MEBIBYTE > $largest,
            "$file: client_max_body_size above "
              . ( $largest / $MEBIBYTE )
              . ' MiB and the form around the file'
        );
    }
};

subtest 'the X-Accel-Redirect alias is the default attachment store' => sub {
    my $root = GPForum::Config->new->attachment_root;
    for my $file (
        qw(deploy/nginx/gpforum.conf deploy/nginx/gpforum-unix-socket.conf))
    {
        my ($alias) = path($file)->slurp =~
m{location [ ] /internal-attachments/ [ ] [{] [^}]* alias [ ] ([^;]+);}msx;
        is( $alias, "$HOME/$root/", "$file serves the attachment root" );
    }
    my $proxy = _section( $guide, 'Reverse Proxy' );
    like(
        $proxy,
        qr/GPFORUM_ATTACHMENT_ACCEL_REDIRECT=\/internal-attachments\//msx,
        'the guide names the setting that turns it on'
    );
    unlike(
        $guide,
        qr/until [ ] an [ ] `X-Accel-Redirect` [ ] header [ ] is/msx,
        'and no longer says the header is not implemented'
    );
};

# The application answers /metrics/ as /metrics; a proxy that kept only the
# exact path to the loopback let the other through.
subtest 'every path that reaches /metrics is kept to the loopback' => sub {
    my $application = GPForum->new;
    my @paths       = grep {
        my $match =
          Mojolicious::Routes::Match->new( root => $application->routes );
        $match->find( $application->build_controller,
            { method => 'GET', path => $_ } );
        ( $match->endpoint // undef )
          && ( $match->stack->[-1]{action} // q{} ) eq 'metrics'
    } qw(/metrics /metrics/ /metrics.json /METRICS);
    is_deeply( \@paths, [qw(/metrics /metrics/)],
        'the application answers /metrics and /metrics/' );

    for my $nginx (
        qw(deploy/nginx/gpforum.conf deploy/nginx/gpforum-unix-socket.conf))
    {
        my $text = path($nginx)->slurp;
        my ($location) =
          $text =~
          /^ [ ]+ location [ ] ~ [ ] (\S+) [ ] [{] \s* allow [ ] 127/msx;
        ok( defined $location, "$nginx: a loopback-only metrics location" );
        for my $request (@paths) {
            like( $request, qr/$location/msx, "$nginx keeps $request to it" );
        }
    }

    my $caddy     = path('deploy/caddy/Caddyfile')->slurp;
    my ($matcher) = $caddy =~ /[@]metrics_remote [ ] [{] ([^}]*) [}]/msx;
    my ($named)   = ( $matcher // q{} ) =~ /^ \s* path [ ] ([^\n]+)$/msx;
    my %named     = map { $_ => 1 } split q{ }, $named // q{};
    for my $request (@paths) {
        ok( $named{$request}, "Caddy names $request" );
    }
    like(
        $matcher // q{},
        qr/not [ ] remote_ip [ ] 127[.]0[.]0[.]1 [ ] ::1/msx,
        'from anywhere but the loopback'
    );
    like( $caddy, qr/respond [ ] [@]metrics_remote [ ] 403/msx, 'is refused' );
};

subtest 'the steps the walkthrough could not find are written down' => sub {
    like(
        $install,
        qr/^ [ ]* sudo [ ] gpforum [ ] setup $/msx,
        'one command for the service user, its file, the database and schema'
    );
    is_deeply(
        GPForum::OS->from_name('linux')
          ->service_account_commands( 'gpforum', $HOME ),
        [
            [
                qw(useradd --system --user-group --home-dir),
                $HOME,
                qw(--shell /usr/sbin/nologin gpforum)
            ]
        ],
        'which makes the service user as the guide made it by hand'
    );
    like(
        $install,
        qr/git [ ] clone [ ] \S+ [ ] \/opt\/gpforum\n/msx,
        'where the code goes'
    );
    like(
        $install,
        qr/The [ ] code [ ] belongs [ ] to [ ] root/msx,
        'and who owns it'
    );
    _has(
        $install,
        q{/etc/gpforum/gpforum.env: written, 0640 root:gpforum, with a new}
          . ' session secret and metrics token',
        'the environment file, its owner, its mode and its secrets'
    );
    _has(
        $install,
        '/opt/gpforum/var/attachments for its uploads',
        'and what the service may write'
    );
    like( $install, qr/certbot [ ] certonly/msx, 'the certificate' );
    like(
        $install,
        qr/systemctl [ ] daemon-reload/msx,
        'and installing the units'
    );
};

subtest 'one install target for production' => sub {
    like(
        $install,
        qr/make [ ] install-deps-production/msx,
        'the install uses install-deps-production'
    );
    unlike( $install, qr/install-deps-postgres/msx, 'and nothing else' );
};

# The commands the install runs through gpforum, the front door, are verbs
# it knows: each runs a GPForum::CLI command.
subtest 'every command the install runs exists' => sub {
    my $code     = join "\n", $install =~ /^ [ ]* ```sh\n (.*?) ^ [ ]* ```/gmsx;
    my $run_as   = qr{(?: sudo [ ] (?: -u [ ] gpforum [ ] )? )?}msx;
    my @commands = $code =~ /^ [ ]* $run_as gpforum [ ] ([[:lower:]-]+)/gmsx;
    ok( scalar @commands, 'the install runs commands through gpforum' );
    my $launcher = GPForum::CLI::FrontDoor::Launcher->new;
    for my $command (@commands) {
        ok( $launcher->resolve($command), "gpforum $command exists" );
    }
    unlike(
        $guide . $readme,
        qr/set [ ] -a; [ ] [.] [ ]/msx,
        'and no step sources the environment file by hand'
    );
    unlike(
        $guide . $readme,
        qr/gpforum-carton [ ] exec [ ] perl [ ] -Ilib/msx,
        'nor runs a command through Carton by hand'
    );
};

# The quick start's database is setup's: as root on Debian it reaches
# PostgreSQL as the postgres account, and the password it makes is in the
# file every gpforum command reads, so nothing is exported by hand.
subtest 'the README quick start works on Debian as written' => sub {
    my ($block) =
      $readme =~ /^[#]{2} [ ] Quick [ ] start\n.*? ^```sh\n(.*?)^```/msx;
    $block //= q{};
    _has(
        $block,
        "\nsudo gpforum setup --environment development ",
        'setup, as root, for development'
    );
    ok( index( $block, 'sudo ln -s' ) < index( $block, 'gpforum setup' ),
        'once gpforum is on the PATH' );
    unlike(
        $block,
        qr/createuser|export [ ] GPFORUM_/msx,
        'with no role made, nor a password exported, by hand'
    );
    is_deeply(
        GPForum::OS->from_name('linux')->postgresql_superuser,
        {
            account => 'postgres',
            role    => 'postgres',
            sockets => [qw(/var/run/postgresql /run/postgresql)],
        },
        q{Debian's superuser, which setup becomes as root}
    );
};

# Iteration 0's quick start ended at an unverified account on a laptop with
# no mail server: development mailed through `test`, which delivers nothing.
# Development now writes the mail to the log, and the quick start says so.
subtest 'the README quick start verifies an account without a mail server' =>
  sub {
    my ($quick) = $readme =~ /^[#]{2} [ ] Quick [ ] start\n(.*?)^[#]{2} [ ]/msx;
    $quick //= q{};
    is( GPForum::Config->from_environment( {} )->mail_transport,
        'log', 'development mails to the log' );
    _has(
        $quick,
        "\nbin/gpforum outbox --once\n",
        'the quick start runs the outbox worker as it is'
    );
    like(
        $quick,
        qr/^gpforum [ ] admin [ ] create [ ] --email [ ]/msx,
        'and makes the first owner without mail'
    );
    unlike(
        $quick,
        qr/GPFORUM_MAIL_TRANSPORT=sendmail [ ] script/msx,
        'without a mail server to send through'
    );
  };

subtest 'GlifiStore is described as the option it is' => sub {
    is( GPForum::Config->from_environment( {} )->glifistore_url,
        q{}, 'no GlifiStore by default' );
    unlike(
        $guide,
        qr/production [ ] require [ ] GlifiStore|GlifiStore [ ] [(]required/msx,
        'and the guide no longer requires one'
    );
};

done_testing();

# Whether a text holds a literal string: commands are quoted as typed.
sub _has ( $text, $literal, $name ) {
    return ok( index( $text, $literal ) >= 0, $name );
}

# A level-two section of a Markdown document, up to the next one.
sub _section ( $text, $title ) {
    my ($section) =
      $text =~ /^[#]{2} [ ] \Q$title\E\n(.*?)(?=^[#]{2} [ ]|\z)/msx;

    return $section // q{};
}

1;
