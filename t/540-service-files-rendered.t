# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use File::Temp qw(tempdir);
use Mojo::DOM;
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::DeployContract qw(
  deploy_match_text
  deploy_unit_checks
);
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceFiles;

our $VERSION = '0.001';

# Audit item C2: the service files deploy/ ships, written for the host they
# go on. Iteration 2 found the launchd plists hard-coding /opt/gpforum, a
# FreeBSD host with no file for its jobs, and every OS but Linux left to
# copy and edit by hand. The templates stay the one copy (t/18 and
# DeployContract read them); what is printed is a template with this
# host's values in place of the template's own.

const my $SITE    => 'https://forum.walk.org';
const my $LAUNCHD => 4;
const my @SOURCED => (
    '/bin/sh',
    '-c',
    'GPFORUM_ENV=production; export GPFORUM_ENV; set -a;'
      . ' [ ! -e "$0" ] || . "$0"; set +a; exec "${@}"',
);
const my $READ_MODE => oct '640';
const my $OPEN_MODE => oct '644';
const my $EXECUTE   => oct '755';

subtest
  'the templates are the source: the documented layout renders them as they are'
  => sub {
    for my $file ( @{ _files( root => '/opt/gpforum' )->render('systemd') } ) {
        is(
            $file->{text},
            path( $file->{template} )->slurp('UTF-8'),
            "$file->{name} is deploy/'s, byte for byte"
        );
    }
    my $rc = _files( root => '/usr/local/www/gpforum', os => 'freebsd' );
    for my $file ( @{ $rc->render('rc') } ) {
        is(
            $file->{text},
            path( $file->{template} )->slurp('UTF-8'),
            "$file->{name} too, under /usr/local/www/gpforum"
        );
    }
  };

subtest 'systemd: the code directory and the environment file of this host' =>
  sub {
    my %unit = map { $_->{name} => $_ }
      @{ _files( root => '/srv/forum' )->render('systemd') };
    is_deeply(
        [ sort keys %unit ],
        [
            sort qw(gpforum.service gpforum-outbox.service
              gpforum-scheduled-jobs.service gpforum-scheduled-jobs.timer
              gpforum-partition-maintenance.service
              gpforum-partition-maintenance.timer)
        ],
        'the web service, the outbox worker and both timers'
    );
    for my $name ( sort keys %unit ) {
        _lacks( $unit{$name}{text},
            '/opt/gpforum', "$name names no /opt/gpforum" );
        is( $unit{$name}{path},
            "/etc/systemd/system/$name", 'and goes where systemd reads it' );
    }
    _line(
        $unit{'gpforum.service'}{text},
        'ExecStart=/srv/forum/bin/gpforum start --service',
        'the web service runs this checkout'
    );
    for my $check ( grep { $unit{ $_->{name} } } deploy_unit_checks() ) {
        my $match = deploy_match_text( $unit{ $check->{name} }{text}, $check );
        is( $match->{status}, 'pass',
            "$check->{name} keeps the deploy contract" );
    }

    my $elsewhere = _files( root => '/srv/forum', file => '/srv/forum.env' );
    my ($outbox) =
      @{ $elsewhere->render( 'systemd', ['gpforum-outbox.service'] ) };
    _line(
        $outbox->{text},
        'EnvironmentFile=/srv/forum.env',
        'and reads the environment file gpforum read'
    );
  };

subtest 'the web unit follows a UNIX socket' => sub {
    my $files = _files(
        settings => {
            GPFORUM_RUNTIME_LISTEN =>
              'http+unix://%2Frun%2Fgpforum%2Fgpforum.sock'
        }
    );
    my ($web) = @{ $files->render( 'systemd', ['gpforum.service'] ) };
    is(
        $web->{template},
        'deploy/systemd/gpforum-unix-socket.service',
        'the socket variant'
    );
    is(
        $web->{path},
        '/etc/systemd/system/gpforum.service',
        'installed as gpforum.service'
    );
};

subtest 'FreeBSD: both rc scripts and the crontab of the jobs' => sub {
    my %file = map { $_->{name} => $_ }
      @{ _files( root => '/srv/forum', os => 'freebsd' )->render('rc') };
    is_deeply(
        [ sort keys %file ],
        [qw(gpforum gpforum_jobs gpforum_outbox)],
        'the web service, the outbox worker and the jobs'
    );
    _line(
        $file{gpforum_outbox}{text},
        ': ${gpforum_home:="/srv/forum"}',
        'the outbox worker runs this checkout'
    );
    is( $file{gpforum}{mode}, $EXECUTE, 'an rc script is written executable' );
    is(
        $file{gpforum_jobs}{path},
        '/usr/local/etc/cron.d/gpforum_jobs',
        'the jobs go where cron reads them'
    );
    my $front_door = q{/srv/forum/bin/gpforum};
    _line(
        $file{gpforum_jobs}{text},
        "0 * * * * gpforum $front_door scheduled-jobs --once --limit 100",
        'hourly, as the gpforum account, through the front door'
    );
    _line(
        $file{gpforum_jobs}{text},
        "17 3 * * * gpforum $front_door partitions --apply",
        'and the partition window daily'
    );

    my ($other) = @{ _files( os => 'freebsd', file => '/srv/forum.env' )
          ->render( 'rc', ['gpforum_jobs'] ) };
    _has(
        $other->{text},
        'bin/gpforum --env-file /srv/forum.env scheduled-jobs',
        'naming an environment file that is not the host one'
    );
};

subtest 'launchd: the service account, this checkout and Homebrew' => sub {
    local $ENV{HOMEBREW_PREFIX} = '/opt/brew';
    my $files  = _files( root => '/Users/admin/gpforum', os => 'darwin' );
    my @plists = @{ $files->render('launchd') };
    is( scalar @plists,
        $LAUNCHD, 'the web service, the outbox worker, both jobs' );
    for my $plist (@plists) {
        my $dom = Mojo::DOM->new->xml(1)->parse( $plist->{text} );
        is( _value( $dom, 'UserName' ), 'gpforum',
            "$plist->{name} as gpforum" );
        _lacks( $plist->{text}, '/opt/gpforum',
            'with no code directory of the template' );
        _lacks( $plist->{text}, '/usr/local/var', 'nor its prefix' );
        _has(
            $plist->{text},
            '<string>/opt/brew/var/log/gpforum/',
            q{logging under Homebrew's prefix}
        );
        is(
            $plist->{path},
            "/Library/LaunchDaemons/$plist->{name}",
            'as a LaunchDaemon'
        );
    }

    for my $plist (@plists) {
        my @arguments = _arguments( $plist->{text} );
        is_deeply(
            [ @arguments[ 0 .. scalar @SOURCED ] ],
            [ @SOURCED, '/opt/brew/etc/gpforum/gpforum.env' ],
            "$plist->{name} reads the host's file before the job starts"
        );
        _lacks( $plist->{text}, '<key>GPFORUM_ENV</key>',
            'and takes the mode from it, not from launchd' );
    }

    my ($outbox) = @{ _files( os => 'darwin', file => '/srv/forum.env' )
          ->render( 'launchd', ['com.gpforum.outbox.plist'] ) };
    my @arguments = _arguments( $outbox->{text} );
    is_deeply(
        [ @arguments[ 0 .. scalar @SOURCED ] ],
        [ @SOURCED, '/srv/forum.env' ],
        'a file that is not the host one is read in its place'
    );
    is( scalar( grep { $_ eq '/bin/sh' } @arguments ),
        1, 'by the one shell, not a second one before it' );
};

subtest 'nginx: the forum, the listen address and the attachment store' => sub {
    my ($site) = @{
        _files(
            root     => '/srv/forum',
            settings => {
                GPFORUM_PUBLIC_BASE_URL => $SITE,
                GPFORUM_RUNTIME_LISTEN  => 'http://*:9000',
                GPFORUM_ATTACHMENT_ROOT => '/data/attachments',
            }
        )->render('nginx')
    };
    my $text = $site->{text};
    _line( $text, '    server_name forum.walk.org;',
        'answers the public name' );
    _has(
        $text,
        '/etc/letsencrypt/live/forum.walk.org/fullchain.pem;',
        'with its certificate'
    );
    _line(
        $text,
        '    server 127.0.0.1:9000;',
        'forwards to where the application listens'
    );
    _line( $text, '        alias /data/attachments/;', 'serves the store' );
    _line( $text, '        root /srv/forum;',          'and the assets' );
    _line( $text, '    client_max_body_size 26m;',     'takes a full upload' );
    _has(
        $text,
"location ~ ^/metrics/?\$ {\n        allow 127.0.0.1;\n        deny all;",
        'and keeps /metrics to this host'
    );
    _lacks( $text, 'forum.example.com', 'nothing of the example name' );
    _lacks( $text, '8080',              'nor of its port' );
    is(
        $site->{path},
        '/etc/nginx/sites-enabled/gpforum',
        q{where Debian's nginx reads it}
    );

    my ($socket) = @{
        _files(
            settings => {
                GPFORUM_PUBLIC_BASE_URL => $SITE,
                GPFORUM_RUNTIME_LISTEN  => 'http+unix://%2Fsrv%2Fgpforum.sock',
            }
        )->render('nginx')
    };
    is(
        $socket->{template},
        'deploy/nginx/gpforum-unix-socket.conf',
        'a socket is the socket site'
    );
    _line(
        $socket->{text},
        '    server unix:/srv/gpforum.sock;',
        'naming that socket'
    );
};

subtest 'Caddy: the forum and the listen address' => sub {
    my ($caddy) = @{
        _files(
            settings => {
                GPFORUM_PUBLIC_BASE_URL => $SITE,
                GPFORUM_RUNTIME_LISTEN  => 'http://127.0.0.1:9000',
            }
        )->render('caddy')
    };
    _line( $caddy->{text}, 'forum.walk.org {', 'answers the name' );
    _line(
        $caddy->{text},
        '    reverse_proxy 127.0.0.1:9000 {',
        'forwards to the application'
    );
    _line(
        $caddy->{text},
        '    respond @metrics_remote 403',
        'and refuses /metrics from elsewhere'
    );

    my ($socket) = @{
        _files(
            settings => {
                GPFORUM_RUNTIME_LISTEN =>
                  'http+unix://%2Frun%2Fgpforum%2Fgpforum.sock'
            }
        )->render('caddy')
    };
    _line(
        $socket->{text},
        '    reverse_proxy unix//run/gpforum/gpforum.sock {',
        'or to its socket'
    );
};

subtest
  'an example or loopback address keeps the template name, and says so' => sub {
    for my $url ( 'https://forum.example.com', 'http://127.0.0.1:3000' ) {
        my $files = _files( settings => { GPFORUM_PUBLIC_BASE_URL => $url } );
        my ($site) = @{ $files->render('nginx') };
        _line(
            $site->{text},
            '    server_name forum.example.com;',
            "$url: the example"
        );
        my ($note) = @{ $files->notes('nginx') };
        is( $note->[0],      'cli.service.placeholder_host', 'with a note' );
        is( $note->[1]{url}, $url, 'naming the address' );
        _lacks( join( "\n", @{ $files->steps('nginx') } ),
            'certbot', 'and no certificate for a name nobody owns' );
    }
  };

subtest 'each operating system puts the files where its own tools read them' =>
  sub {
    is_deeply(
        _files( os => 'linux' )
          ->steps( 'systemd', from => 'units', start => 1 ),
        [
            'sudo cp units/* /etc/systemd/system/',
            'sudo systemctl daemon-reload && sudo systemctl enable --now'
              . ' gpforum gpforum-outbox gpforum-scheduled-jobs.timer'
              . ' gpforum-partition-maintenance.timer',
        ],
        'systemd: one copy, then the reload and the four units, one line'
    );
    is_deeply(
        _files( os => 'freebsd' )->steps( 'rc', from => 'units', start => 1 ),
        [
            'sudo cp units/gpforum units/gpforum_outbox /usr/local/etc/rc.d/',
            'sudo mkdir -p /usr/local/etc/cron.d',
            'sudo cp units/gpforum_jobs /usr/local/etc/cron.d/',
            'sudo sysrc gpforum_enable=YES && sudo service gpforum start',
            'sudo sysrc gpforum_outbox_enable=YES'
              . ' && sudo service gpforum_outbox start',
        ],
        'FreeBSD: the rc scripts, the crontab, and both services enabled'
    );

    local $ENV{HOMEBREW_PREFIX} = '/opt/brew';
    is_deeply(
        _files( os => 'darwin' )
          ->steps( 'launchd', from => 'units', start => 1 ),
        [
            'sudo cp units/* /Library/LaunchDaemons/',
            'sudo install -d -o gpforum -g gpforum -m 0750'
              . ' /opt/brew/var/log/gpforum',
            join q{ },
            'sudo launchctl bootstrap system',
            map { "/Library/LaunchDaemons/com.gpforum.$_.plist" }
              qw(app outbox scheduled-jobs partition-maintenance)
        ],
        'macOS: the plists, the directory they log to, and all loaded at once'
    );

    my %proxy = (
        linux => [
            'sudo certbot certonly --nginx -d forum.walk.org',
            'sudo gpforum service print nginx --to /etc/nginx/sites-enabled',
            'sudo nginx -t && sudo systemctl reload nginx',
        ],
        freebsd => [
            'sudo certbot certonly --standalone -d forum.walk.org'
              . q{ --pre-hook 'service nginx stop'}
              . q{ --post-hook 'service nginx start'},
            'sudo gpforum service print nginx --to /usr/local/etc/nginx/conf.d',
            'sudo nginx -t && sudo service nginx reload',
        ],
        darwin => [
            'sudo certbot certonly --standalone -d forum.walk.org'
              . q{ --pre-hook 'brew services stop nginx'}
              . q{ --post-hook 'brew services start nginx'},
            'gpforum service print nginx --to /opt/brew/etc/nginx/servers',
            'sudo nginx -t && sudo brew services restart nginx',
        ],
    );
    for my $os ( sort keys %proxy ) {
        is_deeply(
            _files(
                os       => $os,
                settings => { GPFORUM_PUBLIC_BASE_URL => $SITE }
            )->steps('nginx'),
            $proxy{$os},
            "nginx on $os"
        );
    }
    is_deeply(
        _files( os => 'darwin' )->steps('caddy'),
        [
            'gpforum service print caddy --to /opt/brew/etc',
            'brew services restart caddy',
        ],
        'and Caddy under Homebrew'
    );
  };

subtest 'the files are printed where the host reads them, then started' => sub {
    my $steps = _files()->steps( 'systemd', start => 1 );
    is_deeply(
        $steps,
        [
            'sudo gpforum service print systemd --to /etc/systemd/system',
            'sudo systemctl daemon-reload && sudo systemctl enable --now'
              . ' gpforum gpforum-outbox gpforum-scheduled-jobs.timer'
              . ' gpforum-partition-maintenance.timer',
        ],
        'into the directory systemd reads, then started: two lines'
    );

    my $one = _files()->steps( 'systemd', names => ['gpforum-outbox.service'] );
    is(
        $one->[0],
        'sudo gpforum service print systemd gpforum-outbox.service'
          . ' --to /etc/systemd/system',
        'one file the same way'
    );
    my $script = _files( os => 'freebsd' )->steps( 'rc', start => 1 );
    is(
        $script->[0],
        'sudo gpforum service print rc --to /usr/local/etc/rc.d',
        'the rc scripts too, which it writes executable'
    );
    is_deeply(
        _files(
            os       => 'linux',
            settings => { GPFORUM_PUBLIC_BASE_URL => $SITE }
        )->steps( 'nginx', in_place => 1 ),
        ['sudo nginx -t && sudo systemctl reload nginx'],
        'once in place, only what makes the proxy read it'
    );
};

subtest 'what the proxy needs comes first, and only when it is missing' => sub {
    is_deeply(
        _files(
            os       => 'linux',
            settings => { GPFORUM_PUBLIC_BASE_URL => $SITE },
            found    => ['certbot'],
        )->steps('nginx')->[0],
        'sudo apt install nginx certbot python3-certbot-nginx',
        'nginx missing: the packages that bring it and certbot'
    );
    is_deeply(
        _files( os => 'darwin', found => [] )->steps('nginx')->[0],
        'brew install nginx certbot',
        'under Homebrew, brew'
    );
    _lacks(
        join(
            "\n",
            @{
                _files(
                    os        => 'linux',
                    settings  => { GPFORUM_PUBLIC_BASE_URL => $SITE },
                    certified => 1,
                )->steps('nginx')
            }
        ),
        'certbot',
        'a certificate already there is not taken again'
    );
    my ($freebsd) = @{
        _files(
            os       => 'freebsd',
            settings => { GPFORUM_PUBLIC_BASE_URL => $SITE }
        )->render('nginx')
    };
    _line(
        $freebsd->{text},
'    ssl_certificate     /usr/local/etc/letsencrypt/live/forum.walk.org/fullchain.pem;',
        q{FreeBSD's certbot keeps it under /usr/local/etc}
    );
};

subtest 'sudo when the environment file is closed to other accounts' => sub {
    my $file = path( tempdir( CLEANUP => 1 ), 'gpforum.env' );
    $file->spew("GPFORUM_ENV=production\n");
    $file->chmod($READ_MODE);
    is(
        _files( file => "$file" )->print_command('nginx'),
        'sudo gpforum service print nginx',
        'root:gpforum 0640, as a deployed file is'
    );
    $file->chmod($OPEN_MODE);
    is(
        _files( file => "$file" )->print_command('nginx'),
        'gpforum service print nginx',
        'and none when anyone may read it'
    );
};

done_testing();

sub _files (%options) {
    my $catalog = GPForum::Service::I18N::CliCatalog->new( language => 'en' );
    my $host    = GPForum::Service::Operations::Host->new(
        catalog     => $catalog,
        environment => 'production',
        os          => GPForum::OS->from_name( $options{os} // 'linux' ),
        defined $options{file} ? ( environment_file => $options{file} ) : (),
    );

    my %found =
      map { $_ => 1 } @{ $options{found} // [qw(nginx certbot caddy)] };
    return GPForum::Service::Operations::ServiceFiles->new(
        environment => $options{settings} // {},
        host        => $host,
        home        => $options{root} // '/opt/gpforum',
        defined $options{file} ? ( environment_file => $options{file} ) : (),
        found  => sub ($program) { return $found{$program} ? 1 : 0 },
        exists => sub ($file) { return $options{certified} ? 1 : 0 },
    );
}

# The string a plist gives a key.
sub _value ( $dom, $key ) {
    my $found = $dom->find('key')->first( sub { $_->text eq $key } );
    return $found ? $found->next->text : undef;
}

# Whether a text holds a line, whole.
sub _line ( $text, $line, $name ) {
    return ok( ( grep { $_ eq $line } split /\n/msx, $text ), $name )
      || diag $text;
}

sub _has ( $text, $literal, $name ) {
    return ok( index( $text, $literal ) >= 0, $name );
}

sub _lacks ( $text, $literal, $name ) {
    return ok( index( $text, $literal ) < 0, $name );
}

# A plist's ProgramArguments, in order.
sub _arguments ($text) {
    my $dom = Mojo::DOM->new->xml(1)->parse($text);

    return map { $_->text } $dom->find('key + array > string')->each;
}

1;
