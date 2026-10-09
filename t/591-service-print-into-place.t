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

use GPForum::Command::Service;
use GPForum::Command::Support::Words;
use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Doctor;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceFiles;
use GPForum::Service::Operations::ServiceUnits;

our $VERSION = '0.001';

# Walkthrough 3, friction 1: Debian took 15 typed commands from the clone to
# TLS, against 8. Four of them were the units' and the site's way into
# place: a print into a directory of one's own, a cp, a daemon-reload, the
# start; then a tee into sites-available, a link into sites-enabled and an
# rm of the default site. `gpforum service print --to` now takes the
# directory the host reads the files from, writes only its own names there
# and leaves everything else alone, and the reload and the start are one
# line. nginx's site goes straight into sites-enabled, after its
# certificate, and Debian's default site stays. macOS loads every plist with
# one launchctl, and gets the account its plists run as (friction 3).

const my $EXIT_FAILURE => 1;
const my $SITE         => 'https://forum.walk.org';
const my $UNITS        => 6;
const my $FREE_ID      => 499;
const my $SECRET       => 'a' x 64;
const my $FIRST_WORDS  => 3;

subtest 'into the directory systemd reads: only its own files, in place' =>
  sub {
    my $system = tempdir( CLEANUP => 1 );
    path( $system, 'sshd.service' )->spew("[Unit]\n");
    my $elsewhere = path( tempdir( CLEANUP => 1 ), 'old.service' );
    $elsewhere->spew("kept\n");
    symlink "$elsewhere", "$system/gpforum.service"
      or croak "symlink: $OS_ERROR";

    my $run = _run( { directories => { systemd => $system } },
        'print', 'systemd', '--to', $system );
    is( $run->{status}, 0, 'written' ) or diag $run->{errors};
    is( path( $system, 'sshd.service' )->slurp,
        "[Unit]\n", q{the directory's other files are left as they are} );
    is(
        scalar(
            grep { /\A gpforum/msx }
            map  { $_->basename } path($system)->list->each
        ),
        $UNITS,
        'the six units are there'
    );
    ok( !-l "$system/gpforum.service",
        'a link under one of their names is replaced by the file' );
    is( $elsewhere->slurp, "kept\n", 'and what it pointed at is untouched' );
    is(
        $run->{output},
        join(
            "\n",
            "\N{CHECK MARK} 6 files for systemd are in $system: " . join(
                q{, },
                qw(gpforum.service gpforum-outbox.service
                  gpforum-scheduled-jobs.service gpforum-scheduled-jobs.timer
                  gpforum-partition-maintenance.service
                  gpforum-partition-maintenance.timer)
              )
              . q{.},
            'Next: start them:',
            '  sudo systemctl daemon-reload && sudo systemctl enable --now'
              . ' gpforum gpforum-outbox gpforum-scheduled-jobs.timer'
              . ' gpforum-partition-maintenance.timer',
            q{}
        ),
        'then one line, the reload and the start: no copy'
    );

    my $other = tempdir( CLEANUP => 1 );
    path( $other, 'notes.txt' )->spew("mine\n");
    my $refused = _run( { directories => { systemd => $system } },
        'print', 'systemd', '--to', $other );
    is( $refused->{status}, $EXIT_FAILURE,
        'any other directory with files of its own is refused, as before' );

    my $blocked = tempdir( CLEANUP => 1 );
    path( $blocked, 'gpforum-outbox.service' )->make_path;
    my $directory = _run( { directories => { systemd => $blocked } },
        'print', 'systemd', '--to', $blocked );
    is( $directory->{status}, $EXIT_FAILURE,
        'and a directory under one of the names is never written over' );
    like( $directory->{errors}, qr/gpforum-outbox[.]service/msx, 'naming it' );
  };

subtest 'nginx: straight into sites-enabled, after its certificate' => sub {
    my $enabled = tempdir( CLEANUP => 1 );
    path( $enabled, 'default' )->spew("server { listen 80 default_server; }\n");
    my %files = (
        directories => { nginx                   => $enabled },
        settings    => { GPFORUM_PUBLIC_BASE_URL => $SITE },
    );

    my $early = _run( \%files, 'print', 'nginx', '--to', $enabled );
    is( $early->{status}, $EXIT_FAILURE, 'refused before the certificate' );
    is(
        $early->{errors},
        'There is no /etc/letsencrypt/live/forum.walk.org/fullchain.pem yet,'
          . ' and nginx refuses a site without its certificate: take it first,'
          . ' with sudo certbot certonly --nginx -d forum.walk.org, then print'
          . " the site again.\n",
        'saying which command takes it'
    );
    ok( !-e "$enabled/gpforum", 'nothing written' );

    my $run =
      _run( { %files, certified => 1 }, 'print', 'nginx', '--to', $enabled );
    is( $run->{status}, 0, 'written once the certificate is there' );
    like(
        path( $enabled, 'gpforum' )->slurp,
        qr/server_name [ ] forum[.]walk[.]org;/msx,
        'as gpforum, the name it is installed under'
    );
    is(
        path( $enabled, 'default' )->slurp,
        "server { listen 80 default_server; }\n",
        q{Debian's default site stays: it answers only names no site claims}
    );
    _has(
        $run->{output},
        "Next: make it take effect:\n"
          . "  sudo nginx -t && sudo systemctl reload nginx\n",
        'then the test and the reload'
    );
    unlike( $run->{output}, qr/rm [ ]/msx, 'and no rm' );
};

subtest 'macOS: every plist loaded at once, and the account they run as' =>
  sub {
    my $host = GPForum::Service::Operations::Host->new(
        catalog => _catalog(),
        os      => GPForum::OS->from_name('darwin'),
    );
    is_deeply(
        [ $host->start_all(qw(gpforum gpforum-outbox)) ],
        [
                'sudo launchctl bootstrap system'
              . ' /Library/LaunchDaemons/com.gpforum.app.plist'
              . ' /Library/LaunchDaemons/com.gpforum.outbox.plist'
        ],
        'one launchctl bootstrap, which takes every path (launchctl(1))'
    );

    my $os       = GPForum::OS->from_name('darwin')->account_id($FREE_ID);
    my @commands = @{ $os->service_account_commands( 'gpforum', '/opt' ) };
    is_deeply(
        [
            map { join q{ }, @{$_}[ 0 .. $FIRST_WORDS ] }
              @commands[ 0, $#commands ]
        ],
        [ 'dscl . -create /Groups/gpforum', 'dscl . -create /Users/gpforum' ],
        'made with dscl, the group first'
    );
    ok(
        (
            grep {
                "@{$_}" eq "dscl . -create /Users/gpforum UniqueID $FREE_ID"
            } @commands
        ),
        'under the id no user and no group has'
    );

    my $taken = GPForum::OS->from_name('darwin')->account_id;
    if ( defined $taken ) {
        ok( !defined getpwuid $taken && !defined getgrgid $taken,
            'which this Mac has free' );
    }
  };

subtest 'doctor: the services without their account' => sub {
    my $doctor = _doctor( account => sub { return 0 } );
    my ($account) =
      grep { $_->{name} eq 'account' } @{ $doctor->check->{findings}->items };
    is( $account->{status}, 'fail', 'none of the services would start' );
    my $text = $doctor->check->{findings}->human_text;
    _has(
        $text,
        "\N{BALLOT X} account gpforum: not on this host, and the services run"
          . " as it\n    Fix: sudo gpforum setup\n",
        'said, with the command that makes it, macOS included'
    );

    my $present = _doctor( account => sub { return 1 } );
    ok(
        !(
            grep { $_->{name} eq 'account' }
            @{ $present->check->{findings}->items }
        ),
        'and nothing when it is there'
    );
};

done_testing();

sub _run ( $options, @arguments ) {
    my $catalog = _catalog();
    my $host    = GPForum::Service::Operations::Host->new(
        catalog     => $catalog,
        environment => 'production',
        os          => GPForum::OS->from_name('linux'),
    );
    my $command = GPForum::Command::Service->new(
        files => GPForum::Service::Operations::ServiceFiles->new(
            directories => $options->{directories} // {},
            environment => $options->{settings}    // {},
            host        => $host,
            home        => '/opt/gpforum',
            found       => sub ($program) { return 1 },
            exists      => sub ($file) { return $options->{certified} ? 1 : 0 },
        ),
        words => GPForum::Command::Support::Words->new( catalog => $catalog ),
    );

    my ( $output, $errors ) = ( q{}, q{} );
    open my $stdout, '>', \$output or croak 'capture stdout';
    open my $stderr, '>', \$errors or croak 'capture stderr';
    $command->output($stdout);
    $command->errors($stderr);
    my $status = $command->run(@arguments);
    close $stdout or croak 'close stdout';
    close $stderr or croak 'close stderr';

    return {
        status => $status,
        output => Mojo::Util::decode( 'UTF-8', $output ),
        errors => Mojo::Util::decode( 'UTF-8', $errors ),
    };
}

sub _doctor (%probes) {
    my $host = GPForum::Service::Operations::Host->new(
        catalog     => _catalog(),
        environment => 'production',
        os          => GPForum::OS->from_name('linux'),
    );

    return GPForum::Service::Operations::Doctor->new(
        catalog     => _catalog(),
        environment => {
            GPFORUM_ENV             => 'production',
            GPFORUM_MAIL_FROM       => 'forum@forum.walk.org',
            GPFORUM_METRICS_TOKEN   => 'metrics-token',
            GPFORUM_PUBLIC_BASE_URL => $SITE,
            GPFORUM_SESSION_SECRET  => $SECRET,
        },
        os     => GPForum::OS->from_name('linux'),
        probes => {
            address   => sub { return { status => 200 } },
            antivirus =>
              sub { return { status => 'disabled', engine => 'none' } },
            budgets =>
              sub { return { missing => [], extra => [], mismatched => [] } },
            database => sub { return { schema => {}, version => '18.6' } },
            mail     => sub {
                return {
                    status => 'pass',
                    probe  => { action => 'log_transport' }
                };
            },
            outbox => sub { return { waiting => 0, last_sent_seconds => 1 } },
            preflight => sub {
                return {
                    checks => [],
                    os     => {
                        name          => 'linux',
                        event_backend => 'epoll',
                        cpu_count     => 2
                    },
                    resources => { file_descriptor_limit => 65_536 },
                    runtime   => { web_processes         => 4 },
                };
            },
            readiness => sub { return { status => 'ok',  checks  => [] } },
            schema    => sub { return { latest => '051', pending => [] } },
            %probes,
        },
        units => GPForum::Service::Operations::ServiceUnits->new(
            directory => tempdir( CLEANUP => 1 ),
            host      => $host,
            systemctl => sub { return undef },
        ),
    );
}

sub _has ( $text, $literal, $name ) {
    return ok( index( $text, $literal ) >= 0, $name ) || diag $text;
}

sub _catalog {
    return GPForum::Service::I18N::CliCatalog->new( language => 'en' );
}

1;
