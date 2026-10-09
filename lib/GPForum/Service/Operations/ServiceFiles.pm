# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::ServiceFiles;

use Const::Fast;
use List::Util qw(any first);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);
use Mojo::URL;
use Mojo::Util qw(decode url_unescape xml_escape);

use GPForum::Config;
use GPForum::OS;
use GPForum::Service::Operations::Host;

our $VERSION = '0.001';

# The service files deploy/ ships, by what runs them, and where each goes on
# a host: the templates stay the only copy (DeployContract and t/18 read
# them), and what an operator installs is a template with this host's
# values in place of the ones it was written with (ADR 0123). Each file names
# its template, the variant installed under the same name when the forum
# listens on a UNIX socket, the service it runs, as systemd names it, and,
# for the crontab, a directory of its own.
const my %TARGET => (
    systemd => {
        os        => 'linux',
        directory => '/etc/systemd/system',
        files     => [
            {
                name       => 'gpforum.service',
                template   => 'deploy/systemd/gpforum.service',
                socket     => 'deploy/systemd/gpforum-unix-socket.service',
                starts     => 'gpforum',
                restarts   => 1,
                front_door => 1,
            },
            {
                name       => 'gpforum-outbox.service',
                template   => 'deploy/systemd/gpforum-outbox.service',
                starts     => 'gpforum-outbox',
                restarts   => 1,
                front_door => 1,
            },
            {
                name       => 'gpforum-scheduled-jobs.service',
                template   => 'deploy/systemd/gpforum-scheduled-jobs.service',
                front_door => 1,
            },
            {
                name     => 'gpforum-scheduled-jobs.timer',
                template => 'deploy/systemd/gpforum-scheduled-jobs.timer',
                starts   => 'gpforum-scheduled-jobs.timer',
                restarts => 1,
            },
            {
                name     => 'gpforum-partition-maintenance.service',
                template =>
                  'deploy/systemd/gpforum-partition-maintenance.service',
                front_door => 1,
            },
            {
                name     => 'gpforum-partition-maintenance.timer',
                template =>
                  'deploy/systemd/gpforum-partition-maintenance.timer',
                starts   => 'gpforum-partition-maintenance.timer',
                restarts => 1,
            },
        ],
        after => ['sudo systemctl daemon-reload'],
    },
    rc => {
        os        => 'freebsd',
        directory => '/usr/local/etc/rc.d',
        files     => [
            {
                name       => 'gpforum',
                template   => 'deploy/freebsd/gpforum',
                starts     => 'gpforum',
                restarts   => 1,
                executable => 1,
            },
            {
                name       => 'gpforum_outbox',
                template   => 'deploy/freebsd/gpforum_outbox',
                starts     => 'gpforum-outbox',
                restarts   => 1,
                executable => 1,
            },

            # cron reads /usr/local/etc/cron.d by itself, and doctor cannot
            # tell this file from the crontab an install before it wrote.
            {
                name        => 'gpforum_jobs',
                template    => 'deploy/freebsd/gpforum_jobs',
                directory   => '/usr/local/etc/cron.d',
                front_door  => 1,
                unwatched   => 1,
                make_parent => 1,
            },
        ],
    },
    launchd => {
        os        => 'darwin',
        directory => '/Library/LaunchDaemons',
        files     => [
            _plist( 'app',            'gpforum' ),
            _plist( 'outbox',         'gpforum-outbox' ),
            _plist( 'scheduled-jobs', 'gpforum-scheduled-jobs.timer' ),
            _plist(
                'partition-maintenance', 'gpforum-partition-maintenance.timer'
            ),
        ],
        logs => 1,
    },
    nginx => {
        proxy => 'nginx',
        files => [
            {
                name     => 'gpforum.conf',
                template => 'deploy/nginx/gpforum.conf',
                socket   => 'deploy/nginx/gpforum-unix-socket.conf',
            },
        ],
    },
    caddy => {
        proxy => 'caddy',
        files =>
          [ { name => 'Caddyfile', template => 'deploy/caddy/Caddyfile' } ],
    },
);

# A launchd job's property list, and the service it runs as systemd names
# it: launchd loads each, the jobs included, and a new copy of any is read
# only once it is loaded again.
sub _plist ( $job, $starts ) {
    return {
        name       => "com.gpforum.$job.plist",
        template   => "deploy/launchd/com.gpforum.$job.plist",
        starts     => $starts,
        restarts   => 1,
        front_door => 1,
    };
}

# The order the help and the misuse list them in.
const my @TARGETS => qw(systemd rc launchd nginx caddy);

# Where a proxy's configuration goes, by operating system, the name it goes
# under there, and what makes the proxy read it: the programs it needs and
# the packages that bring them, the command that takes the certificate the
# site names, and the reload. A site goes straight where the proxy reads
# it -- Debian's nginx includes sites-enabled/* -- and Debian's default site
# stays: it answers only the names no other site claims. Homebrew's prefix
# belongs to the operator, so nothing there needs sudo.
const my %PROXY => (
    nginx => {
        linux => {
            directory => '/etc/nginx/sites-enabled',
            name      => 'gpforum',
            needs     => [qw(nginx certbot)],
            packages  => 'sudo apt install nginx certbot python3-certbot-nginx',
            certificate => 'sudo certbot certonly --nginx -d {host}',
            after       => ['sudo nginx -t && sudo systemctl reload nginx'],
        },
        freebsd => {
            directory   => '/usr/local/etc/nginx/conf.d',
            name        => 'gpforum.conf',
            needs       => [qw(nginx certbot)],
            packages    => 'sudo pkg install www/nginx security/py-certbot',
            certificate => 'sudo certbot certonly --standalone -d {host}'
              . q{ --pre-hook 'service nginx stop'}
              . q{ --post-hook 'service nginx start'},
            after       => ['sudo nginx -t && sudo service nginx reload'],
            notes       => ['cli.service.nginx_include'],
            make_parent => 1,
        },
        darwin => {
            directory   => '{prefix}/etc/nginx/servers',
            name        => 'gpforum.conf',
            needs       => [qw(nginx certbot)],
            packages    => 'brew install nginx certbot',
            certificate => 'sudo certbot certonly --standalone -d {host}'
              . q{ --pre-hook 'brew services stop nginx'}
              . q{ --post-hook 'brew services start nginx'},

            # As root, which reads the certificate certbot keeps root's.
            after => ['sudo nginx -t && sudo brew services restart nginx'],
            owned => 1,
        },
    },
    caddy => {
        linux => {
            directory => '/etc/caddy',
            name      => 'Caddyfile',
            needs     => ['caddy'],
            packages  => 'sudo apt install caddy',
            after     => ['sudo systemctl reload caddy'],
            notes     => ['cli.service.caddy_whole'],
        },
        freebsd => {
            directory => '/usr/local/etc/caddy',
            name      => 'Caddyfile',
            needs     => ['caddy'],
            packages  => 'sudo pkg install www/caddy',
            after     => ['sudo service caddy reload'],
            notes     => ['cli.service.caddy_whole'],
        },
        darwin => {
            directory => '{prefix}/etc',
            name      => 'Caddyfile',
            needs     => ['caddy'],
            packages  => 'brew install caddy',
            after     => ['brew services restart caddy'],
            notes     => ['cli.service.caddy_whole'],
            owned     => 1,
        },
    },
);

# Where certbot keeps the certificates, which the nginx site names: FreeBSD's
# port keeps them under /usr/local/etc.
const my %LETSENCRYPT => ( freebsd => '/usr/local/etc/letsencrypt' );

# Where a program a proxy needs may be, besides the PATH: sudo's PATH has
# /usr/sbin, where Debian's nginx is, and a login shell may not.
const my @PROGRAM_DIRECTORIES =>
  qw(/usr/sbin /usr/local/sbin /usr/local/bin /opt/homebrew/bin /usr/bin);

# The values each template was written with, which a host's take the place
# of: the code directory, the environment file, the launchd logs, the
# forum's public name, where the application listens and the attachment
# store's alias.
const my %WRITTEN => (
    systemd => {
        root     => '/opt/gpforum',
        env_file => '/etc/gpforum/gpforum.env',
    },
    rc => {
        root     => '/usr/local/www/gpforum',
        env_file => '/usr/local/etc/gpforum/gpforum.env',
    },
    launchd => {
        root     => '/opt/gpforum',
        logs     => '/usr/local/var/log/gpforum',
        env_file => '/usr/local/etc/gpforum/gpforum.env',
    },
    nginx => {
        root        => '/opt/gpforum',
        attachments => '/opt/gpforum/var/attachments/',
        host        => 'forum.example.com',
        upstream    => '127.0.0.1:8080',
        socket      => '/run/gpforum/gpforum.sock',
        letsencrypt => '/etc/letsencrypt',
    },
    caddy => {
        root     => '/opt/gpforum',
        host     => 'forum.example.com',
        upstream => '127.0.0.1:8080',
    },
);

# The names kept for examples, and the loopback: not the one members reach
# the forum at, so the proxy keeps the template's name and the operator is
# told.
const my @EXAMPLE_NAMES =>
  qw(example example.com example.net example.org invalid test localhost);
const my $LOOPBACK => qr{\A (?: 127[.] | \[? ::1 \]? \z )}msx;

# An address the application listens on every interface of, which the proxy
# on this host reaches on the loopback.
const my %ANY_ADDRESS =>
  ( q{*} => '127.0.0.1', '0.0.0.0' => '127.0.0.1', q{[::]} => '[::1]' );

# A file name a shell takes bare; any other is single-quoted.
const my $SHELL_SAFE => qr{\A [\w/.,:@%+=-]+ \z}msx;

const my $STAT_MODE   => 2;
const my $OTHERS_READ => oct '004';
const my $EXECUTABLE  => oct '755';
const my $READABLE    => oct '644';

# The checkout whose deploy/ is rendered.
has root => sub {
    return path(__FILE__)
      ->realpath->dirname->dirname->dirname->dirname->dirname->to_string;
};

# The code directory the services run from: this checkout, unless a test
# names another.
has home => sub ($self) { return $self->root; };

# The host the files and commands are written for.
has host => sub { return GPForum::Service::Operations::Host->new; };

# The settings the proxy and the web unit follow, as the front door loaded
# them; a test gives its own.
has environment => sub { return \%ENV; };

# The environment file the settings were read from, when the caller knows
# it: the front door's, or doctor's.
has environment_file => undef;    # optional: the host's otherwise

# The directory each target's files go in, by target, in place of this
# host's own; a test gives its own.
has directories => sub { return {}; };

# Whether a program is installed, and whether a file is there; a test gives
# its own.
has found => sub {
    return sub ($program) {
        return ( any { -x "$_/$program" }
              ( split( /:/msx, $ENV{PATH} // q{} ), @PROGRAM_DIRECTORIES ) )
          ? 1
          : 0;
    };
};
has exists => sub {
    return sub ($file) { return -e $file ? 1 : 0; };
};

sub targets ($class) {
    return [@TARGETS];
}

sub is_target ( $class, $name ) {
    return exists $TARGET{ $name // q{} } ? 1 : 0;
}

# This host's service manager, or undef where GPForum ships none.
sub default_target ($self) {
    return $self->host->service_manager;
}

# A target's files as { name, template, installed, destination, path,
# starts, restarts, executable, unwatched, privileged, make_parent }: the
# name it is installed under, the directory it goes in and the full path
# there, whether writing there needs root, and whether that directory may
# not exist yet. Given a directory, the files that go in the target's own
# go there instead -- doctor's, a test's.
sub files ( $self, $target, $directory = undef ) {
    my $layout = _layout($target);
    my $place =
      $layout->{proxy} ? $self->_proxy_place( $layout->{proxy} ) : {};
    my @files;
    for my $file ( @{ $layout->{files} } ) {
        my %file = %{$file};
        my $here = $file{directory} // $directory // $self->_directory($target);
        my $installed = $place->{name} // $file{name};
        push @files,
          {
            %file,
            destination => $here,
            installed   => $installed,
            path        => "$here/$installed",
            privileged  => $place->{owned} ? 0 : 1,
            make_parent => $file{make_parent} || $place->{make_parent}
            ? 1
            : 0,
          };
    }

    return \@files;
}

# The file names a target installs, in order.
sub names ( $self, $target ) {
    return [ map { $_->{name} } @{ $TARGET{$target}{files} } ];
}

# The files of a target, rendered with this host's values: each file of
# files() with its text and the mode to write it with. Given names, those
# files only.
sub render ( $self, $target, $names = [], $directory = undef ) {
    my %wanted = map { $_ => 1 } @{$names};
    my @rendered;
    for my $file ( @{ $self->files( $target, $directory ) } ) {
        next if %wanted && !$wanted{ $file->{name} };
        my $template = $self->template_of( $target, $file );
        push @rendered,
          {
            %{$file},
            template => $template,
            text     => $self->render_template( $target, $template, $file ),
            mode     => $file->{executable} ? $EXECUTABLE : $READABLE,
          };
    }

    return \@rendered;
}

# The template a file is rendered from: the UNIX-socket variant when the
# forum listens on one.
sub template_of ( $self, $target, $file ) {
    return $file->{socket} && defined $self->_socket
      ? $file->{socket}
      : $file->{template};
}

# One template's text with this host's values in place of the ones it was
# written with, in one pass, so a value is never replaced twice.
sub render_template ( $self, $target, $template, $file = {} ) {
    my $text    = path( $self->root, $template )->slurp('UTF-8');
    my %written = %{ $WRITTEN{$target} };
    my %value   = $self->_values($target);
    my %replace = map { $written{$_} => $value{$_} }
      grep { defined $value{$_} && $written{$_} ne $value{$_} } keys %written;

    if (%replace) {
        my $alternatives = join q{|},
          map { quotemeta } reverse sort { length $a <=> length $b }
          keys %replace;
        $text =~ s{($alternatives)(?![\w-])}{$replace{$1}}gmsx;
    }
    if ( my $file_read = $self->_other_env_file($target) ) {
        $text = $self->_reading( $target, $text, $file_read, $file );
    }

    return $text;
}

# What the operator reads beside the files: a public address the proxy
# cannot be written for, and what a proxy's host needs besides the file.
# Each a [ key, parameters ] pair of the command-line catalog.
sub notes ( $self, $target ) {
    my $proxy = _layout($target)->{proxy};
    return [] if !defined $proxy;

    my @notes;
    my $url  = $self->_setting('GPFORUM_PUBLIC_BASE_URL');
    my $host = $self->_public_host;
    if ( !defined $host ) {
        push @notes,
          [
            'cli.service.placeholder_host',
            {
                url      => $url,
                host     => $WRITTEN{$target}{host},
                variable => 'GPFORUM_PUBLIC_BASE_URL',
                where    => $self->host->where,
            }
          ];
    }
    my $place = $self->_proxy_place($proxy);
    for my $key ( @{ $place->{notes} // [] } ) {
        push @notes, [ $key, { host => $host // $WRITTEN{$target}{host} } ];
    }

    return \@notes;
}

# The commands that put a target's files in place and, with start, start
# what they run, as an operator types them. What the proxy needs comes
# first: its packages, when a program is missing, and the certificate the
# site names, for the forum's own name. Then gpforum service print --to the
# directory the host reads the files from, which puts each in place; from a
# directory --to wrote them to, the copies instead; with in_place, nothing,
# the files being there. Then the reload, and the start, on one line under
# systemd. Given names, those files only.
sub steps ( $self, $target, %options ) {
    my @files = @{ $self->files( $target, $options{directory} ) };
    if ( $options{names} ) {
        my %wanted = map { $_ => 1 } @{ $options{names} };
        @files = grep { $wanted{ $_->{name} } } @files;
    }
    return [] if !@files;

    my $all  = @files == @{ $TARGET{$target}{files} };
    my $from = $options{from};
    my $place =
      _layout($target)->{proxy}
      ? $self->_proxy_place( _layout($target)->{proxy} )
      : {};

    my @steps =
      $options{in_place} ? ()
      : (
        $self->_needed($place),
        defined $from ? _copied( \@files, $from, $all )
        : $self->_printed_into_place( $target, \@files, $all )
      );

    return [
        @steps,
        $self->_reload_and_start( $target, \@files, $place, $options{start} )
    ];
}

# gpforum service print --to the directory the host reads the files from,
# naming the files when they are not all of the target's: through sudo when
# writing there needs root.
sub _printed_into_place ( $self, $target, $files, $all ) {
    my $print =
      $self->print_command( $target, $all ? () : map { $_->{name} } @{$files} );
    if ( ( any { $_->{privileged} } @{$files} ) && $print !~ /\A sudo /msx ) {
        $print = "sudo $print";
    }

    return "$print --to $files->[0]{destination}";
}

# What makes the manager or the proxy read the files, then, when asked, what
# starts what they run: one line under systemd, the reload before the start.
sub _reload_and_start ( $self, $target, $files, $place, $start ) {
    my @after = (
        @{ _layout($target)->{after} // [] },
        map { $self->_filled($_) } @{ $place->{after} // [] }
    );
    my @start = $start ? $self->_started( $target, $files ) : ();
    if ( $target eq 'systemd' && @after && @start ) {
        @start = ( join( q{ && }, @after, shift @start ), @start );
        @after = ();
    }

    return ( @after, @start );
}

# The step that writes this host's service files where its service manager
# reads them -- gpforum service print --to that directory, the first of
# steps() -- which setup and secret rotate offer before the services are in
# place. A bare print wrote every unit to the terminal before saying to use
# --to. Undef where GPForum ships no service files.
sub install_step ($self) {
    my $target = $self->default_target;
    return undef if !defined $target;

    return
      first { /\b gpforum [ ] service [ ] print \b/msx }
      @{ $self->steps( $target, start => 1 ) };
}

# The command that takes the certificate the proxy's site names, for the
# forum's own name; undef for a proxy that takes its own, or for an example
# name, which would never be issued.
sub certificate_command ($self) {
    my $place = $self->_proxy_place(q{nginx});
    return undef
      if !defined $place->{certificate} || !defined $self->_public_host;

    return $self->_filled( $place->{certificate} );
}

# What a proxy needs before its site goes in place: the packages, when one
# of its programs is not installed, and the certificate, when it is not
# there yet.
sub _needed ( $self, $place ) {
    my @steps;
    if ( any { !$self->found->($_) } @{ $place->{needs} // [] } ) {
        push @steps, $place->{packages};
    }
    my $host = $self->_public_host;
    if (   defined $place->{certificate}
        && defined $host
        && !$self->exists->( $self->_letsencrypt . "/live/$host/fullchain.pem" )
      )
    {
        push @steps, $self->_filled( $place->{certificate} );
    }

    return @steps;
}

# Where certbot keeps its certificates on this host.
sub _letsencrypt ($self) {
    my $os = $self->host->os->name;

    return exists $LETSENCRYPT{$os}
      ? $LETSENCRYPT{$os}
      : $WRITTEN{nginx}{letsencrypt};
}

# How to type gpforum service print for a target and the names given: with
# sudo when the environment file it reads is closed to other accounts, as a
# deployed one is (root:gpforum, 0640), so the operator's own account can
# read it and write the files where it is told.
sub print_command ( $self, $target, @names ) {
    my $file = $self->environment_file // $self->host->os->environment_file;
    my $mode = ( stat $file )[$STAT_MODE];
    my $sudo = defined $mode && !( $mode & $OTHERS_READ ) ? 'sudo ' : q{};

    return join q{ }, "${sudo}gpforum service print", $target, @names;
}

# The services a target's files run, as systemd names them, that a restart
# picks the new files up in.
sub restarted ( $self, $target, @names ) {
    my %wanted = map { $_ => 1 } @names;
    return [
        map  { $_->{starts} }
        grep { $_->{restarts} && ( !@names || $wanted{ $_->{name} } ) }
          @{ $self->files($target) }
    ];
}

# Homebrew's prefix: the directory macOS's environment file is under
# (GPForum::OS::Darwin), where the launchd logs and the proxies' files go.
sub _homebrew_prefix {
    return GPForum::OS->from_name('darwin')->environment_file =~
      s{ /etc/gpforum/gpforum[.]env \z}{}rmsx;
}

# A target's entry, as a hash any key may be asked of.
sub _layout ($target) {
    return { %{ $TARGET{$target} } };
}

# The values of a target's host: what each template's own is replaced with.
sub _values ( $self, $target ) {
    my %value = ( root => $self->home );
    if ( exists $WRITTEN{$target}{env_file} ) {
        $value{env_file} = $self->env_file($target);
    }
    if ( _layout($target)->{logs} ) {
        $value{logs} = _homebrew_prefix() . '/var/log/gpforum';
    }
    if ( _layout($target)->{proxy} ) {
        $value{host}        = $self->_public_host;
        $value{attachments} = $self->_attachments;
        $value{letsencrypt} = $self->_letsencrypt;
        my $socket = $self->_socket;
        $value{socket}   = $socket;
        $value{upstream} = defined $socket
          && $target eq 'caddy' ? "unix/$socket" : $self->_upstream;
    }

    return %value;
}

# The environment file a target's services read: the one the settings were
# read from, when that is not this host's own, else the target's operating
# system's.
sub env_file ( $self, $target ) {
    return $self->_other_env_file($target)
      // $self->_target_os($target)->environment_file;
}

sub _other_env_file ( $self, $target ) {
    my $file = $self->environment_file;
    return undef if !defined $file;
    return undef if $file eq $self->host->os->environment_file;
    return undef if $file eq $self->_target_os($target)->environment_file;

    return $file;
}

sub _target_os ( $self, $target ) {
    my $name = _layout($target)->{os};
    return defined $name ? GPForum::OS->from_name($name) : $self->host->os;
}

# A file that reads an environment file other than the one the front door
# reads by itself: the systemd units', the crontab's and the launchd jobs'
# commands name it with --env-file, so bin/gpforum reads the file the unit
# gives the service and not the host's beside it -- and the web service,
# told it in GPFORUM_ENV_FILE, follows that one's metrics tokens (ADR
# 0124). The rc scripts pass their gpforum_env_file themselves. A plist
# takes it as two more arguments after bin/gpforum.
sub _reading ( $self, $target, $text, $file_read, $file ) {
    return $text if !$file->{front_door};

    if ( $target eq 'launchd' ) {
        my $escaped = xml_escape($file_read);
        $text =~ s{(<string>[^<]*/bin/gpforum</string>) (\s+)}
                  {$1$2<string>--env-file</string>$2<string>$escaped</string>$2}gmsx;
        return $text;
    }

    my $quoted = _shell_quoted($file_read);
    $text =~ s{(/bin/gpforum) [ ]}{$1 --env-file $quoted }gmsx;

    return $text;
}

# The host members reach the forum at, from GPFORUM_PUBLIC_BASE_URL, as
# nginx, Caddy and certbot take it -- an accented name in its xn-- form;
# undef when that is an example name or the loopback, which the proxy
# cannot be written for.
sub _public_host ($self) {
    my $host =
      Mojo::URL->new( $self->_setting('GPFORUM_PUBLIC_BASE_URL') )->host;
    return undef if !defined $host || !length $host || $host =~ $LOOPBACK;

    my @labels = split /[.]/msx, lc $host;
    for my $from ( 0 .. $#labels ) {
        my $tail = join q{.}, @labels[ $from .. $#labels ];
        return undef if any { $tail eq $_ } @EXAMPLE_NAMES;
    }

    # The environment holds the name as UTF-8 bytes.
    return Mojo::URL->new->host( lc( decode( 'UTF-8', $host ) // $host ) )
      ->ihost;
}

# The first address GPFORUM_RUNTIME_LISTEN names over TCP, as the proxy on
# this host reaches it; the template's when it names no port.
sub _upstream ($self) {
    my ($first) = split /\s*,\s*/msx,
      $self->_setting('GPFORUM_RUNTIME_LISTEN') =~ s/\A\s+//rmsx;
    my $url  = Mojo::URL->new( $first // q{} );
    my $host = $url->host;
    my $port = $url->port;
    return $WRITTEN{nginx}{upstream} if !defined $host || !defined $port;

    return ( exists $ANY_ADDRESS{$host} ? $ANY_ADDRESS{$host} : $host )
      . ":$port";
}

# The socket GPFORUM_RUNTIME_LISTEN names, or undef when it listens on TCP.
sub _socket ($self) {
    my ($encoded) = $self->_setting('GPFORUM_RUNTIME_LISTEN') =~
      m{\A \s* http[+]unix:// ([^,?\s]+)}msx;
    return defined $encoded ? url_unescape($encoded) : undef;
}

# The attachment store's directory, with the trailing slash an nginx alias
# needs: a relative GPFORUM_ATTACHMENT_ROOT starts at the code directory.
sub _attachments ($self) {
    my $store = $self->_setting('GPFORUM_ATTACHMENT_ROOT') =~ s{/+\z}{}rmsx;
    if ( $store !~ m{\A /}msx ) {
        $store = path( $self->home, $store )->to_string;
    }

    return "$store/";
}

# A setting as the service reads it: the environment's value, else
# GPForum's default.
sub _setting ( $self, $variable ) {
    my $value = $self->environment->{$variable};
    return $value if defined $value && length $value;

    my $setting =
      first { $_->{env} eq $variable } @{ GPForum::Config->settings };
    return $setting ? $setting->{default} // q{} : q{};
}

# Where a target's files go on this host.
sub _directory ( $self, $target ) {
    return $self->directories->{$target}
      if exists $self->directories->{$target};

    my $proxy = _layout($target)->{proxy};
    return _layout($target)->{directory} if !defined $proxy;

    return $self->_filled( $self->_proxy_place($proxy)->{directory} );
}

# A proxy's place on this host's operating system, Linux's elsewhere.
sub _proxy_place ( $self, $proxy ) {
    my $places = $PROXY{$proxy};
    my $os     = $self->host->os->name;

    return { %{ exists $places->{$os} ? $places->{$os} : $places->{linux} } };
}

# A command with this host's values in: {host}, the forum's public name, and
# {prefix}, Homebrew's.
sub _filled ( $self, $command ) {
    my %value = (
        host   => $self->_public_host // $WRITTEN{nginx}{host},
        prefix => _homebrew_prefix(),
    );

    return $command =~ s{ [{] (host|prefix) [}] }{$value{$1}}grmsx;
}

# The files copied from the directory they were written to, one command a
# destination: the directory's files at once when they all go to the same
# place under the names they were written with.
sub _copied ( $files, $from, $all ) {
    my @destinations;
    my %by_destination;
    for my $file ( @{$files} ) {
        my $destination = $file->{destination};
        if ( !exists $by_destination{$destination} ) {
            push @destinations, $destination;
        }
        push @{ $by_destination{$destination} }, $file;
    }

    my @steps;
    for my $destination (@destinations) {
        my @here = @{ $by_destination{$destination} };
        my $sudo = $here[0]{privileged} ? 'sudo ' : q{};
        if ( any { $_->{make_parent} } @here ) {
            push @steps, "${sudo}mkdir -p $destination";
        }
        my $renamed = any { $_->{installed} ne $_->{name} } @here;
        my $sources =
          $all && @destinations == 1 && !$renamed && @here > 1
          ? "$from/*"
          : join q{ }, map { "$from/$_->{name}" } @here;
        my $into = $renamed && @here == 1 ? $here[0]{path} : "$destination/";
        push @steps, "${sudo}cp $sources $into";
    }

    return @steps;
}

# The commands that start what the files run.
sub _started ( $self, $target, $files ) {
    my @services = map { $_->{starts} // () } @{$files};
    my $os       = _layout($target)->{os};
    my $host     = GPForum::Service::Operations::Host->new(
        catalog => $self->host->catalog,
        os      => defined $os ? GPForum::OS->from_name($os) : $self->host->os,
    );
    my @steps;
    if ( _layout($target)->{logs} ) {
        my %value = $self->_values($target);
        push @steps,
          "sudo install -d -o gpforum -g gpforum -m 0750 $value{logs}";
    }

    return @steps, $host->start_all(@services);
}

sub _shell_quoted ($text) {
    return $text if $text =~ $SHELL_SAFE;

    return q{'} . ( $text =~ s/'/'\\''/grmsx ) . q{'};
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::ServiceFiles - The service and proxy files
deploy/ ships, written for this host.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $files = GPForum::Service::Operations::ServiceFiles->new(
        environment_file => '/etc/gpforum/gpforum.env' );
    for my $file ( @{ $files->render('systemd') } ) {
        say "$file->{path}:";
        print $file->{text};
    }
    say for @{ $files->steps( 'systemd', from => '~/units', start => 1 ) };

=head1 DESCRIPTION

What C<gpforum service print> prints and C<gpforum doctor> compares the
installed files with: the systemd units, the FreeBSD rc scripts and crontab,
the launchd property lists, and the nginx and Caddy sites of F<deploy/>,
each with this host's values where the template has the ones it was
written with -- the code directory, the environment file, Homebrew's prefix
for the launchd logs, the forum's public name from
C<GPFORUM_PUBLIC_BASE_URL>, the address the application listens on from
C<GPFORUM_RUNTIME_LISTEN>, and the attachment store from
C<GPFORUM_ATTACHMENT_ROOT>. The templates stay the only copy. It also
writes the commands that put the files in place on each operating system
and start what they run. It installs nothing.

=head1 SUBROUTINES/METHODS

=head2 root

The checkout whose F<deploy/> templates are rendered.

=head2 home

The code directory the services run from, which the files name: L</root>
unless given.

=head2 host

The L<GPForum::Service::Operations::Host> the files and commands are written
for.

=head2 environment

The settings, C<%ENV> by default.

=head2 environment_file

The environment file the settings were read from, when the caller knows it.

=head2 directories

The directory each target's files go in, by target, where this host's own
is not the one meant.

=head2 found

A code reference that says whether a program is installed: on the C<PATH>
or in the system's own directories, by default.

=head2 exists

A code reference that says whether a file is there.

=head2 targets

Class method. C<systemd>, C<rc>, C<launchd>, C<nginx> and C<caddy>.

=head2 is_target

Class method. Whether a name is one of L</targets>.

=head2 default_target

This host's service manager, or undef.

=head2 files

A target's files, each with its C<name>, C<template>, the C<installed> name,
the C<destination> directory and the C<path> there, and what it runs.

=head2 names

The names of a target's files, in order.

=head2 render

A target's files, or the ones named, with their C<text> rendered for this
host and the C<mode> to write them with.

=head2 template_of

The template a file is rendered from: its UNIX-socket variant when the
application listens on a socket.

=head2 render_template

A template's text with this host's values in place of the template's own.

=head2 notes

What to read beside a target's files, as C<[ key, parameters ]> pairs of the
command-line catalog.

=head2 steps

The commands that put a target's files in place: a proxy's packages when a
program it needs is missing, and its certificate when it is not there yet;
then C<gpforum service print --to> the directory the host reads the files
from, or the copies from the directory given as C<from>, or nothing with
C<in_place>; then the reload and, with C<start>, the commands that start
what they run, on one line under systemd.

=head2 install_step

The command that writes this host's service files where its service
manager reads them, C<gpforum service print --to> that directory, or undef
where GPForum ships none.

=head2 certificate_command

The command that takes the certificate the nginx site names, for the
forum's own name on this operating system, or undef.

=head2 print_command

How to type C<gpforum service print> for a target and the files named.

=head2 restarted

The services, as systemd names them, that run a target's files and pick a
new copy up only when restarted.

=head2 env_file

The environment file a target's services read.

=head1 DIAGNOSTICS

None: a template that cannot be read dies with L<Mojo::File>'s error.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<GPFORUM_PUBLIC_BASE_URL>, C<GPFORUM_RUNTIME_LISTEN> and
C<GPFORUM_ATTACHMENT_ROOT> from C<environment>, and C<HOMEBREW_PREFIX>
through L<GPForum::OS>.

=head1 DEPENDENCIES

L<GPForum::Config>, L<GPForum::OS>, L<GPForum::Service::Operations::Host>,
L<Mojo::File>, L<Mojo::URL>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The proxy follows the first address C<GPFORUM_RUNTIME_LISTEN> names, over
plain HTTP. The service account is C<gpforum>, as every template and the
deployment guide name it. The nginx site names certbot's F<live/>
directory, under F</usr/local/etc/letsencrypt> on FreeBSD and
F</etc/letsencrypt> elsewhere.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
