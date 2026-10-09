# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::CLI::start;
use GPForum::Command::Support::ServiceEnvironment;
use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::DeployContract qw(
  deploy_match_text
  deploy_unit_checks
);
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceFiles;
use GPForum::Service::Operations::ServiceUnits;

our $VERSION = '0.001';

# Walkthrough 3, friction 11: the printed units still ran
# script/gpforum-carton exec and script/os-preflight, where owner decision D9
# keeps script/ for the maintainers. The units now run bin/gpforum alone,
# which finds the Perl and the dependencies the checkout installed itself:
# `gpforum os-preflight --strict --json` before the start, `gpforum start
# --service` for Hypnotoad, and the verbs for the outbox worker and the jobs.
# A unit copied before this release keeps working, so it keeps the deploy
# contract, and doctor says it differs from the release's.

const my $ROOT          => path(q{.})->to_abs->to_string;
const my $LABEL         => 'ExecStart through bin/gpforum';
const my $OTHER         => '/srv/forum.env';
const my @IN_FOREGROUND => qw(start --service --foreground);
const my $RC_PATH       => qr{/usr/bin/env [ ] PATH=[\$][{]gpforum_path[}]}msx;
const my $RC_FRONT_DOOR =>
  qr{[\$][{]gpforum_home[}]/bin/gpforum [ ] --env-file [ ] \S+}msx;
const my %LAYOUT => (
    systemd => 'linux',
    rc      => 'freebsd',
    launchd => 'darwin',
);

subtest 'no service file runs anything of script/' => sub {
    for my $target ( sort keys %LAYOUT ) {
        for my $root ( '/opt/gpforum', '/srv/forum' ) {
            for my $file (
                @{ _files( $LAYOUT{$target}, $root )->render($target) } )
            {
                my @running = grep { !/\A \s* (?: [#] | <!-- ) /msx }
                  split /\n/msx, $file->{text};
                is_deeply( [ grep { m{/script/}msx } @running ],
                    [], "$target $file->{name} under $root" );
            }
        }
    }
};

subtest 'systemd: os-preflight, then Hypnotoad, through bin/gpforum' => sub {
    my %unit = map { $_->{name} => $_ }
      @{ _files( 'linux', '/srv/forum' )->render('systemd') };
    my $web = $unit{'gpforum.service'}{text};
    _line(
        $web,
        'ExecStartPre=/srv/forum/bin/gpforum os-preflight --strict --json',
        'the host is checked by the verb'
    );
    _line(
        $web,
        'ExecStart=/srv/forum/bin/gpforum start --service',
        'and Hypnotoad started by it'
    );
    _line(
        $unit{'gpforum-outbox.service'}{text},
        'ExecStart=/srv/forum/bin/gpforum outbox --loop --limit 100 --sleep 5',
        'the outbox worker is gpforum outbox'
    );
    _line(
        $unit{'gpforum-partition-maintenance.service'}{text},
        'ExecStart=/srv/forum/bin/gpforum partitions --apply',
        'the partition window gpforum partitions'
    );

    my ($other) = @{ _files( 'linux', '/srv/forum', $OTHER )
          ->render( 'systemd', ['gpforum.service'] ) };
    _line(
        $other->{text},
        "ExecStart=/srv/forum/bin/gpforum --env-file $OTHER start --service",
        'printed for another environment file, bin/gpforum reads that one'
    );
    my ($check) = grep { $_->{name} eq 'gpforum.service' } deploy_unit_checks();
    my $match = deploy_match_text( $other->{text}, $check );
    ok(
        ( grep { $_ eq $LABEL } @{ $match->{matched_labels} } ),
        'and still starts the way the contract says'
    );
};

subtest 'launchd and rc start Hypnotoad in the foreground' => sub {
    local $ENV{HOMEBREW_PREFIX} = '/opt/brew';
    my ($plist) = @{ _files( 'darwin', '/srv/forum' )
          ->render( 'launchd', ['com.gpforum.app.plist'] ) };
    my @arguments = $plist->{text} =~ m{<string>([^<]*)</string>}gmsx;
    my ($at) =
      grep { $arguments[$_] eq '/srv/forum/bin/gpforum' } 0 .. $#arguments;
    ok( defined $at, 'launchd runs bin/gpforum' );
    is_deeply( [ @arguments[ $at + 1 .. $at + scalar @IN_FOREGROUND ] ],
        [@IN_FOREGROUND],
        'as start --service --foreground, which launchd supervises' );

    my ($rc) =
      @{ _files( 'freebsd', '/srv/forum' )->render( 'rc', ['gpforum'] ) };
    like(
        $rc->{text},
        qr{$RC_PATH [ ] \S+ [ ] $RC_FRONT_DOOR [ ] start [ ] --service}msx,
        'daemon(8) runs it with /usr/local/bin, where perl is, on its PATH'
    );
    like(
        $rc->{text},
        qr{gpforum_path:="/usr/local/bin:}msx,
        'which rc itself does not have'
    );
};

subtest 'gpforum start --service runs Hypnotoad from local/ in its place' =>
  sub {
    my $root = tempdir( CLEANUP => 1 );
    path( $root, 'local', 'bin' )->make_path;
    path( $root, 'local', 'lib', 'perl5' )->make_path;
    path( $root, 'local', 'bin', 'hypnotoad' )->spew("#!perl\n");

    my $read = path( $root, 'forum.env' );
    $read->spew("GPFORUM_ENV=production\n");
    GPForum::Command::Support::ServiceEnvironment->new(
        file        => "$read",
        environment => {},
    )->load;
    for my $case ( [ [], [] ], [ ['--foreground'], ['-f'] ] ) {
        my ( $options, $flags ) = @{$case};
        my @ran;
        local $ENV{PERL5LIB}         = '/elsewhere';
        local $ENV{GPFORUM_ENV_FILE} = undef;
        my $start = GPForum::CLI::start->new(
            root    => $root,
            replace => sub (@command) { @ran = @command; },
        );
        is( $start->run( '--service', @{$options} ), 0, 'it runs' );
        is_deeply(
            \@ran,
            [
                $EXECUTABLE_NAME, "$root/local/bin/hypnotoad",
                @{$flags},        "$root/bin/gpforum"
            ],
            'Hypnotoad on bin/gpforum, by this Perl'
              . ( @{$flags} ? ', in the foreground' : q{} )
        );
        like(
            $ENV{PERL5LIB},
            qr{\A \Q$root\E/local/lib/perl5 : /elsewhere \z}msx,
            q{with local/ on the PERL5LIB its own restarts inherit}
        );
        is( $ENV{GPFORUM_ENV_FILE}, "$read",
            'and the file the front door read, which the service reads too' );
    }

    my $empty = tempdir( CLEANUP => 1 );
    my $said  = q{};
    my $status;
    {
        local $ENV{LC_ALL} = 'en_US.UTF-8';
        open my $errors, '>', \$said or croak "capture: $OS_ERROR";
        local *STDERR = $errors;
        $status = GPForum::CLI::start->new(
            root    => $empty,
            replace => sub (@) { fail('nothing is run') },
        )->run('--service');
        close $errors or croak "capture: $OS_ERROR";
    }
    is( $status, 1, 'without the dependencies, it stops' );
    like(
        $said,
        qr{\AThere [ ] is [ ] no [ ] \Q$empty\E/local/bin/hypnotoad, [ ] so}msx,
        'and says why'
    );
  };

subtest 'a unit copied before this release keeps working' => sub {
    my $host      = _host('linux');
    my $directory = tempdir( CLEANUP => 1 );
    my $files     = _files( 'linux', $ROOT );
    for my $file ( @{ $files->render( 'systemd', [], $directory ) } ) {
        path( $file->{path} )->spew( _as_before( $file->{text} ), 'UTF-8' );
    }
    my $old = path( $directory, 'gpforum.service' )->slurp;
    like(
        $old,
        qr{script/gpforum-carton [ ] exec [ ] hypnotoad}msx,
        'the old web unit ran Hypnotoad through script/gpforum-carton'
    );

    for my $check ( grep { -e path( $directory, $_->{name} ) }
        deploy_unit_checks() )
    {
        my $text  = path( $directory, $check->{name} )->slurp;
        my $match = deploy_match_text( $text, $check );
        is( $match->{status}, 'pass', "$check->{name} keeps the contract" );
    }

    my $found = GPForum::Service::Operations::ServiceUnits->new(
        directory => $directory,
        host      => $host,
        root      => $ROOT,
        systemctl => sub { return undef },
    )->units( _findings() );
    is( $found->status, 'degraded', 'doctor says it, without a failure' );
    like(
        $found->human_text,
        qr/differ [ ] from [ ] this [ ] release/msx,
        'as units that differ from the release'
    ) or diag $found->human_text;
};

done_testing();

# The commands as the units before this release ran them.
sub _as_before ($text) {
    $text =~ s{^ExecStartPre=(\S+)/bin/gpforum[ ]os-preflight[ ]}
              {ExecStartPre=$1/script/os-preflight }gmsx;
    $text =~ s{^ExecStart=(\S+)/bin/gpforum[ ]start[ ]--service$}
              {ExecStart=$1/script/gpforum-carton exec hypnotoad $1/bin/gpforum}gmsx;
    $text =~ s{^ExecStart=(\S+)/bin/gpforum[ ]outbox[ ]}
              {ExecStart=$1/script/gpforum-carton exec $1/bin/gpforum-outbox-dispatch }gmsx;
    $text =~ s{^ExecStart=(\S+)/bin/gpforum[ ]scheduled-jobs[ ]}
              {ExecStart=$1/script/gpforum-carton exec $1/bin/gpforum-scheduled-jobs }gmsx;

    return $text;
}

sub _files ( $os, $root, $file = undef ) {
    return GPForum::Service::Operations::ServiceFiles->new(
        home => $root,
        host => _host( $os, $file ),
        defined $file ? ( environment_file => $file ) : (),
        environment => { GPFORUM_PUBLIC_BASE_URL => 'https://forum.walk.org' },
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

sub _line ( $text, $line, $name ) {
    return ok( ( grep { $_ eq $line } split /\n/msx, $text ), $name )
      || diag $text;
}

sub _catalog {
    return GPForum::Service::I18N::CliCatalog->new( language => 'en' );
}

sub _findings {
    return GPForum::Service::Operations::Findings->new( catalog => _catalog() );
}

1;
