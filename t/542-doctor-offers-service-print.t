# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Doctor;
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceFiles;
use GPForum::Service::Operations::ServiceUnits;

our $VERSION = '0.001';

# What gpforum doctor offers for the service files, now that gpforum service
# print writes them for the host (iteration 2, frictions 4 and 5): the units
# it printed read as this release's, wherever the checkout is; a missing or
# drifted one is printed again, one command, not a cp of long absolute
# paths; a missing plist is loaded with launchctl; and the proxy step is
# the one for this operating system's nginx, not Debian's everywhere.

const my $ROOT   => path(q{.})->to_abs->to_string;
const my $SITE   => 'https://forum.walk.org';
const my $SECRET => 'a' x 64;

subtest 'units printed for this checkout are as this release ships them' =>
  sub {
    my $host      = _host('linux');
    my $directory = _install( $host, 'systemd' );
    unlike( path( $directory, 'gpforum.service' )->slurp,
        qr{/opt/gpforum}msx, 'written for this checkout, not /opt/gpforum' );
    my $found = _units( $host, $directory )->units( _findings() );
    is( $found->status, 'ok', 'nothing to fix' );
    like(
        $found->human_text,
        qr/services: [ ] 6 [ ] files [ ] in [ ]/msx,
        'all six counted'
    ) or diag $found->human_text;

    my $file      = path( tempdir( CLEANUP => 1 ), 'forum.env' )->to_string;
    my $elsewhere = _host( 'linux', $file );
    my $read      = _install( $elsewhere, 'systemd' );
    my $other     = _units( $elsewhere, $read )->units( _findings() );
    is( $other->status, 'ok',
        'and so are units that read another environment file' )
      or diag $other->human_text;
  };

subtest 'units copied from deploy/ before it are still as shipped' => sub {
    my $directory = tempdir( CLEANUP => 1 );
    for my $file ( path('deploy/systemd')->list->each ) {
        next if $file->basename eq 'gpforum-unix-socket.service';
        $file->copy_to( path( $directory, $file->basename ) );
    }
    is( _units( _host('linux'), $directory )->units( _findings() )->status,
        'ok', 'an install from before gpforum service print reads as current' );
};

subtest 'launchd: a missing plist is printed, copied and loaded' => sub {
    my $host      = _host('darwin');
    my $directory = _install( $host, 'launchd' );
    unlink "$directory/com.gpforum.outbox.plist";
    my $text = _units( $host, $directory )->units( _findings() )->human_text;
    _has(
        $text,
        'Fix: sudo gpforum service print launchd com.gpforum.outbox.plist'
          . " --to $directory\n",
        'printed for this host into place'
    );
    _has(
        $text,
        'sudo launchctl bootstrap system'
          . " /Library/LaunchDaemons/com.gpforum.outbox.plist\n",
        'then loaded, which the cp alone never did'
    );
    _lacks( $text, "$ROOT/deploy/", q{no path into the checkout's deploy/} );

    my $drifted = _install( $host, 'launchd' );
    my $plist   = path( $drifted, 'com.gpforum.app.plist' );
    $plist->spew( $plist->slurp =~ s/65536/1024/rmsx );
    my $again = _units( $host, $drifted )->units( _findings() )->human_text;
    _has(
        $again,
        'sudo launchctl bootout system/com.gpforum.app && sudo launchctl'
          . ' bootstrap system /Library/LaunchDaemons/com.gpforum.app.plist',
'a changed one is booted out and loaded again: a kickstart keeps the old'
    );
};

subtest 'rc: a missing script is printed into place and started' => sub {
    my $host      = _host('freebsd');
    my $directory = _install( $host, 'rc' );
    unlink "$directory/gpforum_outbox";
    my $text = _units( $host, $directory )->units( _findings() )->human_text;
    _has(
        $text,
        "Fix: sudo gpforum service print rc gpforum_outbox --to $directory\n",
        'printed into place, executable'
    );
    _has(
        $text,
        'sudo sysrc gpforum_outbox_enable=YES'
          . " && sudo service gpforum_outbox start\n",
        'and started'
    );
};

subtest 'missing units are printed where systemd reads them, then started' =>
  sub {
    my $directory = tempdir( CLEANUP => 1 );
    my $text =
      _units( _host('linux'), $directory )->units( _findings() )->human_text;
    my ($fix) = $text =~ /^ \s+ (Fix: .*) \z/msx;
    is_deeply(
        [ grep { !/things? [ ] to [ ] fix/msx } split /\n\s*/msx, $fix // q{} ],
        [
            "Fix: sudo gpforum service print systemd --to $directory",
            'sudo systemctl daemon-reload && sudo systemctl enable --now'
              . ' gpforum gpforum-outbox gpforum-scheduled-jobs.timer'
              . ' gpforum-partition-maintenance.timer',
        ],
        'a fresh host: one print, then one line that starts them'
    );
  };

subtest 'the proxy step is the one for this operating system' => sub {
    local $ENV{HOMEBREW_PREFIX} = '/opt/brew';
    my %expected = (
        linux => [
            'sudo gpforum service print nginx --to /etc/nginx/sites-enabled',
            'sudo nginx -t && sudo systemctl reload nginx',
        ],
        freebsd => [
            'sudo gpforum service print nginx --to /usr/local/etc/nginx/conf.d',
            'sudo nginx -t && sudo service nginx reload',
        ],
        darwin => [
            'sudo certbot certonly --standalone -d forum.walk.org --pre-hook',
            'gpforum service print nginx --to /opt/brew/etc/nginx/servers',
            'sudo nginx -t && sudo brew services restart nginx',
        ],
    );
    for my $os ( sort keys %expected ) {
        my $text = _proxy_down($os);
        _has(
            $text,
            "Fix: put GPForum's nginx site in place:\n",
            "$os: the proxy is put in place"
        );
        for my $step ( @{ $expected{$os} } ) {
            _has( $text, $step, "with $step" );
        }
        _lacks( $text, 'DEPLOYMENT', 'not a step of a guide' );
    }
};

done_testing();

# A unit directory holding a target's files as gpforum service print wrote
# them for the host.
sub _install ( $host, $target ) {
    my $directory = tempdir( CLEANUP => 1 );
    my $files     = GPForum::Service::Operations::ServiceFiles->new(
        host => $host,
        root => $ROOT,
        defined $host->environment_file
        ? ( environment_file => $host->environment_file )
        : (),
    );
    for my $file ( @{ $files->render( $target, [], $directory ) } ) {
        next if $file->{unwatched};
        path( $file->{path} )->spew( $file->{text}, 'UTF-8' );
    }

    return $directory;
}

sub _units ( $host, $directory ) {
    return GPForum::Service::Operations::ServiceUnits->new(
        directory => $directory,
        host      => $host,
        root      => $ROOT,
        systemctl => sub { return undef },
    );
}

sub _host ( $os, $file = undef ) {
    return GPForum::Service::Operations::Host->new(
        catalog     => _catalog(),
        environment => 'production',
        os          => GPForum::OS->from_name($os),
        defined $file ? ( environment_file => $file ) : (),
    );
}

# What doctor says of an address nothing answers at, on a host of the
# operating system named.
sub _proxy_down ($os) {
    my $host   = _host($os);
    my %probes = (
        address   => sub { return { error  => 'refused',  kind => 'refused' } },
        antivirus => sub { return { status => 'disabled', engine => 'none' } },
        budgets   =>
          sub { return { missing => [], extra => [], mismatched => [] } },
        database => sub { return { schema => {}, version => '18.6' } },
        mail     => sub {
            return { status => 'pass', probe => { action => 'log_transport' } };
        },
        outbox    => sub { return { waiting => 0, last_sent_seconds => 1 } },
        preflight => sub {
            return {
                checks => [],
                os     =>
                  { name => $os, event_backend => 'kqueue', cpu_count => 2 },
                resources => { file_descriptor_limit => 65_536 },
                runtime   => { web_processes         => 4 },
            };
        },
        readiness => sub { return { status => 'ok',  checks  => [] } },
        schema    => sub { return { latest => '051', pending => [] } },
    );
    my $doctor = GPForum::Service::Operations::Doctor->new(
        catalog     => _catalog(),
        environment => {
            GPFORUM_ENV             => 'production',
            GPFORUM_MAIL_FROM       => 'forum@forum.walk.org',
            GPFORUM_METRICS_TOKEN   => 'metrics-token',
            GPFORUM_PUBLIC_BASE_URL => $SITE,
            GPFORUM_SESSION_SECRET  => $SECRET,
        },
        os     => GPForum::OS->from_name($os),
        probes => \%probes,
        units  => _units( $host, tempdir( CLEANUP => 1 ) ),
    );

    my ($address) =
      grep { $_->{name} eq 'address' } @{ $doctor->check->{findings}->items };
    my $findings = _findings();
    $findings->add( %{$address} );

    return $findings->human_text;
}

sub _has ( $text, $literal, $name ) {
    return ok( index( $text, $literal ) >= 0, $name ) || diag $text;
}

sub _lacks ( $text, $literal, $name ) {
    return ok( index( $text, $literal ) < 0, $name );
}

sub _catalog {
    return GPForum::Service::I18N::CliCatalog->new( language => 'en' );
}

sub _findings {
    return GPForum::Service::Operations::Findings->new( catalog => _catalog() );
}

1;
