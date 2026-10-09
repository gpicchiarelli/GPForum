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
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceUnits;

our $VERSION = '0.001';

# Iteration 2's acceptance for gpforum doctor (audit 5.4): on a broken host
# it lists every problem with a Fix: that works. The ten breakages the audit
# names -- DB down, wrong password, migrations pending, outbox stopped, clamd
# absent, wrong public URL, missing secret, timer disabled, unit drifted,
# proxy down -- each come out as their own line, naming the variable, the
# file or the command; a healthy host reads as check marks and "Nothing to
# fix." The host itself is replaced by doubles (the probes); what the real
# probes do against PostgreSQL is t/integration/postgres-doctor.t, and the
# service files and timers t/494.

const my $FILE    => '/etc/gpforum/gpforum.env';
const my $WAITING => 3;
const my $STALLED => 1_380;
const my $SECONDS => 4;
const my $HOURS   => 7_200;
const my $DAY     => 86_400;
const my $DAYS    => 259_200;
const my $FDS     => 65_536;
const my $WEB     => 4;
const my $SECRET  => '0123456789abcdef' x 3;
const my %PRODUCTION => (
    GPFORUM_ENV             => 'production',
    GPFORUM_MAIL_FROM       => 'forum@forum.gpforum.net',
    GPFORUM_METRICS_TOKEN   => 'metrics-token',
    GPFORUM_PUBLIC_BASE_URL => 'https://forum.gpforum.net',
    GPFORUM_SESSION_SECRET  => $SECRET,
);
const my $REFUSED => 'DBI connect(\'dbname=gpforum;host=127.0.0.1;port=5432\','
  . '\'gpforum\',...) failed: connection to server at "127.0.0.1", port 5432'
  . ' failed: Connection refused';
const my $PASSWORD => 'DBI connect(\'dbname=gpforum;host=127.0.0.1;port=5432\','
  . '\'gpforum\',...) failed: connection to server at "127.0.0.1", port 5432'
  . ' failed: FATAL:  password authentication failed for user "gpforum"';

local $ENV{GPFORUM_ENV} = 'development';

subtest 'a healthy development checkout is check marks only' => sub {
    my $text = _text( _doctor( { GPFORUM_ENV => 'development' } ) );
    is(
        $text,
        join( "\n",
"\N{CHECK MARK} settings: development, from the shell's environment",
            "\N{CHECK MARK} host: Linux with epoll, 2 CPUs",
            "\N{CHECK MARK} web processes: 4 for 2 CPUs",
            "\N{CHECK MARK} open files: up to 65536",
"\N{CHECK MARK} database: PostgreSQL 18.6, gpforum at 127.0.0.1:5432",
            "\N{CHECK MARK} schema: current (051)",
            "\N{CHECK MARK} query budgets: as the code sets them",
            "\N{CHECK MARK} readiness: 2 more checks of /health/ready pass",
            "\N{CHECK MARK} outbox worker: nothing waiting; the last message"
              . ' left 4 s ago',
            "\N{CHECK MARK} mail: written to the log, not sent"
              . ' (GPFORUM_MAIL_TRANSPORT=log)',
"\N{CHECK MARK} antivirus: off; uploads are checked for format only",
            "\N{CHECK MARK} address: http://127.0.0.1:3000 answers",
            q{},
            'Nothing to fix.' )
          . "\n",
        'every check, one line each, and the count'
    );
};

subtest 'settings it cannot use are every problem, and the rest waits' => sub {
    my $doctor = _doctor(
        {
            GPFORUM_ENV             => 'prod',
            GPFORUM_PUBLIC_BASE_URL => 'forum.gpforum.net',
        }
    );
    my $result = $doctor->check;
    ok( $result->{waiting}, 'the other checks wait for the settings' );
    is( $result->{findings}->exit_status, 1, 'and it fails' );
    my $text = $result->{findings}->human_text;
    _has(
        $text,
        'GPFORUM_ENV must be one of',
        'the mistyped environment is named'
    );
    _has(
        $text,
        "Fix: set GPFORUM_ENV=production in $FILE",
        'with the setting to write, in the file read'
    );
    _has(
        $text,
        'GPFORUM_PUBLIC_BASE_URL must be a full',
        'and the second problem in the same run'
    );
    unlike( $text, qr/database:/msx, 'nothing that needs the settings ran' );
};

subtest 'the ten breakages, each with its fix' => sub {
    my %deployed = %PRODUCTION;
    my $missing  = { %deployed, GPFORUM_METRICS_TOKEN => q{} };
    _says(
        _doctor( $missing, os => 'linux' ),
        ['GPFORUM_METRICS_TOKEN is required in production'],
        ['Fix: sudo gpforum secret rotate metrics'],
        'missing secret'
    );
    _says(
        _doctor( \%deployed, os => 'linux', database => _dies($REFUSED) ),
        ["\N{BALLOT X} database: cannot reach PostgreSQL at 127.0.0.1:5432"],
        [
            'Fix: start it with sudo systemctl start postgresql',
            "GPFORUM_DATABASE_DSN in $FILE",
        ],
        'DB down'
    );
    _says(
        _doctor( \%deployed, os => 'linux', database => _dies($PASSWORD) ),
        ['refused the password of role gpforum'],
        ["Fix: correct GPFORUM_DATABASE_PASSWORD in $FILE"],
        'wrong password'
    );
    _says(
        _doctor(
            \%deployed,
            os     => 'linux',
            schema => sub {
                return {
                    latest  => '051',
                    pending => [
                        { version => '050', description => 'one' },
                        { version => '051', description => 'two' },
                    ],
                };
            }
        ),
        ['schema: 2 migrations to apply, 050 to 051'],
        ["gpforum migrate\n"],
        'migrations pending'
    );
    _says(
        _doctor(
            \%deployed,
            os     => 'linux',
            outbox => sub {
                return { waiting => $WAITING, oldest_seconds => $STALLED };
            }
        ),
        ['outbox worker: 3 messages waiting, the oldest for 23 min'],
        [
            'Fix: sudo systemctl enable --now gpforum-outbox',
            'journalctl -u gpforum-outbox says why',
        ],
        'outbox stopped'
    );
    _says(
        _doctor(
            \%deployed,
            os        => 'linux',
            antivirus => sub {
                return {
                    status => 'fail',
                    engine => 'clamd',
                    health => {
                        socket => '/run/clamav/clamd.ctl',
                        error  => 'cannot connect to clamd at'
                          . ' /run/clamav/clamd.ctl: No such file or directory',
                    },
                };
            }
        ),
        ['antivirus: clamd does not answer at /run/clamav/clamd.ctl'],
        [
            'Fix: sudo apt install clamav-daemon',
            "GPFORUM_ANTIVIRUS=none in $FILE",
        ],
        'clamd absent'
    );
    _says(
        _doctor(
            \%deployed,
            os      => 'linux',
            address => sub {
                return {
                    error => 'Name or service not known',
                    kind  => 'unresolved'
                };
            }
        ),
        [
                'address: https://forum.gpforum.net does not answer:'
              . ' its host name is not known'
        ],
        ["GPFORUM_PUBLIC_BASE_URL in $FILE"],
        'wrong public URL'
    );
    _says(
        _doctor(
            \%deployed,
            os      => 'linux',
            address => sub {
                return { error => 'Connection refused', kind => 'refused' };
            }
        ),
        ['does not answer: connection refused'],
        [
            q{Fix: put GPForum's nginx site in place:},
            'sudo gpforum service print nginx --to /etc/nginx/sites-enabled',
            'sudo nginx -t && sudo systemctl reload nginx',
            "sudo systemctl enable --now gpforum\n",
        ],
        'proxy down'
    );
};

subtest 'Italian, as LC_ALL asks' => sub {
    my $text = _text(
        _doctor(
            {%PRODUCTION},
            catalog =>
              GPForum::Service::I18N::CliCatalog->new( language => 'it' ),
            database => _dies($REFUSED),
            os       => 'linux',
        )
    );
    _has(
        $text,
        'PostgreSQL non risponde su 127.0.0.1:5432',
        'the database sentence'
    );
    _has( $text, 'Rimedio: avvialo con', 'its fix' );
    _has( $text, "cose da sistemare.\n", 'and the count' );
};

subtest 'a duration reads as an operator reads one' => sub {
    my $doctor = _doctor( { GPFORUM_ENV => 'development' } );
    for my $case (
        [ $SECONDS => '4 s' ],
        [ $STALLED => '23 min' ],
        [ $HOURS   => '2 h' ],
        [ $DAY     => '1 day' ],
        [ $DAYS    => '3 days' ],
      )
    {
        my ( $seconds, $said ) = @{$case};
        is( $doctor->age($seconds), $said, "$seconds s read as $said" );
    }
};

subtest 'the settings problems an archived report carries hide secrets' => sub {
    my $problems = GPForum::Service::Operations::Doctor->settings_problems(
        { %PRODUCTION, GPFORUM_SESSION_SECRET => 'short-secret-value' } );
    is_deeply(
        [ map { $_->{variable} } @{$problems} ],
        ['GPFORUM_SESSION_SECRET'],
        'the short secret is the problem'
    );
    unlike( $problems->[0]{sentence},
        qr/short-secret-value/msx, 'and its value is not in the sentence' );
};

done_testing();

# A doctor on doubles for every probe: a healthy host unless a test replaces
# one.
sub _doctor ( $environment, %replace ) {
    my $os      = delete $replace{os};
    my $catalog = delete $replace{catalog}
      // GPForum::Service::I18N::CliCatalog->new( language => 'en' );
    my %probes = (
        address   => sub { return { code   => 200 } },
        antivirus => sub { return { status => 'disabled', engine => 'none' } },
        budgets   =>
          sub { return { missing => [], extra => [], mismatched => [] } },
        database     => sub { return { schema => {}, version => '18.6' } },
        dependencies => sub {
            return {
                status => 'ok',
                count  => 18,
                perl   => '5.44.0',
                map { $_ => [] } qw(missing outdated broken)
            };
        },
        mail => sub {
            return { status => 'pass', probe => { action => 'log_transport' } };
        },
        outbox =>
          sub { return { waiting => 0, last_sent_seconds => $SECONDS } },
        preflight => sub {
            return {
                checks => [],
                os     =>
                  { name => 'linux', event_backend => 'epoll', cpu_count => 2 },
                resources => { file_descriptor_limit => $FDS },
                runtime   => { web_processes         => $WEB },
            };
        },
        readiness => sub {
            return {
                status => 'ok',
                checks => [
                    { name => 'database',          status => 'ok' },
                    { name => 'partition_horizon', status => 'ok' },
                    {
                        name   => 'shared_cache',
                        status => 'ok',
                        mode   => 'disabled'
                    },
                ],
            };
        },
        schema => sub { return { latest => '051', pending => [] } },
        %replace,
    );

    return GPForum::Service::Operations::Doctor->new(
        catalog     => $catalog,
        environment => $environment,
        file   => $environment->{GPFORUM_ENV} eq 'development' ? undef : $FILE,
        probes => \%probes,
        ( $os ? ( os => GPForum::OS->from_name($os) ) : () ),
        units => _units($catalog),
    );
}

# Service files are t/494's: here, every unit installed as shipped, and no
# systemctl to ask about them.
sub _units ($catalog) {
    my $directory = tempdir( CLEANUP => 1 );
    for my $file ( path('deploy/systemd')->list->each ) {
        $file->copy_to( path( $directory, $file->basename ) );
    }

    return GPForum::Service::Operations::ServiceUnits->new(
        directory => $directory,
        host      => GPForum::Service::Operations::Host->new(
            catalog     => $catalog,
            environment => 'production',
            os          => GPForum::OS->from_name('linux'),
        ),
        systemctl => undef,
    );
}

sub _dies ($message) {
    return sub { die "$message\n" };
}

sub _text ($doctor) {
    return $doctor->check->{findings}->human_text;
}

sub _says ( $doctor, $problems, $fixes, $name ) {
    my $text = _text($doctor);
    for my $phrase ( @{$problems} ) {
        _has( $text, $phrase, "$name: the problem" );
    }
    for my $phrase ( @{$fixes} ) {
        _has( $text, $phrase, "$name: the fix" );
    }
    like( $text, qr/to [ ] fix[.]\n\z/msx, "$name: counted" );

    return;
}

sub _has ( $text, $phrase, $name ) {
    ok( index( $text, $phrase ) >= 0, $name ) or diag $text;

    return;
}

1;
