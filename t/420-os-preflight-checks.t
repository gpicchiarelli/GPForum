# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';

use GPForum::OS;
use GPForum::OS::Preflight;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::OSPreflight;

our $VERSION = '0.001';

# The checks and the human lines OS::Preflight builds in place, read from a
# profile given whole, so each boundary and each line is pinned rather than
# only the overall status a real OS happens to produce.

const my $FD_LIMIT        => 100;
const my $FD_AT_RATIO     => 80;
const my $FD_OVER_RATIO   => 81;
const my $FD_FLOOR        => 65_536;
const my $CPU_COUNT       => 4;
const my $WEB_PROCESSES   => 8;
const my $NICE_DELTA      => 10;
const my $DEFAULT_WORKERS => 2;

subtest 'descriptor usage is degraded only above 80 percent' => sub {
    is_deeply(
        _check( 'file_descriptor_usage', open => $FD_AT_RATIO ),
        { name => 'file_descriptor_usage', status => 'ok' },
        'exactly 80 percent is still ok'
    );
    is_deeply(
        _check( 'file_descriptor_usage', open => $FD_OVER_RATIO ),
        {
            name       => 'file_descriptor_usage',
            status     => 'degraded',
            reason     => 'open file descriptor usage is above 80 percent',
            key        => 'preflight.usage_high',
            parameters => {
                open    => $FD_OVER_RATIO,
                limit   => $FD_LIMIT,
                minimum => $FD_LIMIT,
            },
        },
        'one more descriptor is degraded, with the sentence and its values'
    );
};

subtest 'an unknown open count is reported once, without arithmetic' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $report = _preflight( open => undef )->report;

    is_deeply(
        _named( $report, 'open_file_descriptors' ),
        {
            name       => 'open_file_descriptors',
            status     => 'degraded',
            reason     => 'open file descriptor count unavailable',
            key        => 'preflight.open_unknown',
            parameters => {},
        },
        'the open count check says it is unavailable'
    );
    is_deeply(
        _named( $report, 'file_descriptor_usage' ),
        { name => 'file_descriptor_usage', status => 'ok' },
        'usage is not judged without the open count'
    );
    is_deeply( \@warnings, [], 'and nothing divides an undefined count' );
};

subtest 'the descriptor limit floor is inclusive' => sub {
    is(
        _check(
            q{file_descriptor_limit},
            floor => $FD_FLOOR,
            limit => $FD_FLOOR
        )->{status},
        'ok',
        'a limit at the floor is ok'
    );
    is_deeply(
        _check(
            q{file_descriptor_limit},
            floor => $FD_FLOOR,
            limit => $FD_FLOOR - 1
        ),
        {
            name   => 'file_descriptor_limit',
            status => 'degraded',
            reason =>
              'file descriptor limit is below recommended deployment floor',
            key        => 'preflight.limit_low',
            parameters => { limit => $FD_FLOOR - 1, minimum => $FD_FLOOR },
        },
        'one below the floor is degraded'
    );
};

subtest q{the open descriptor threshold is inclusive} => sub {
    is_deeply(
        _check(
            q{open_file_descriptors},
            open     => $FD_AT_RATIO,
            max_open => $FD_AT_RATIO
        ),
        { name => q{open_file_descriptors}, status => q{ok} },
        q{as many open as the threshold allows is ok}
    );
    is_deeply(
        _check(
            q{open_file_descriptors},
            open     => $FD_OVER_RATIO,
            max_open => $FD_AT_RATIO
        ),
        {
            name   => q{open_file_descriptors},
            status => q{degraded},
            reason =>
              q{open file descriptor count exceeds configured threshold},
            key        => q{preflight.open_over},
            parameters => { open => $FD_OVER_RATIO, maximum => $FD_AT_RATIO },
        },
        q{one more is degraded}
    );
};

subtest 'each requested feature is judged by its own OS support' => sub {
    is_deeply(
        _check(
            'features',
            features  => { reuseport => { setting => 'on' } },
            reuseport => 0,
            sendfile  => 1,
        ),
        {
            name       => 'features',
            status     => 'degraded',
            reason     => 'reuseport explicitly requested but unsupported',
            key        => 'preflight.feature_unsupported',
            parameters =>
              { feature => 'reuseport', variable => 'GPFORUM_OS_REUSEPORT' },
        },
        'reuseport without SO_REUSEPORT is degraded, whatever sendfile says'
    );
    is(
        _check(
            'features',
            features  => { reuseport => { setting => 'on' } },
            reuseport => 1,
            sendfile  => 0,
        )->{status},
        'ok',
        'reuseport with SO_REUSEPORT is ok without sendfile'
    );
    is_deeply(
        _check(
            'features',
            features  => { static_xsendfile => { setting => 'on' } },
            reuseport => 1,
            sendfile  => 0,
        ),
        {
            name   => 'features',
            status => 'degraded',
            reason => 'static_xsendfile explicitly requested but unsupported',
            key    => 'preflight.feature_unsupported',
            parameters => {
                feature  => 'static_xsendfile',
                variable => 'GPFORUM_OS_STATIC_XSENDFILE',
            },
        },
        'X-Sendfile needs sendfile, not SO_REUSEPORT'
    );
    is(
        _check(
            'features',
            features  => { sendfile => { setting => 'auto' } },
            reuseport => 0,
            sendfile  => 0,
        )->{status},
        'ok',
        'a feature left on auto is never a broken request'
    );
};

subtest 'what an operator reads: what passes, then each problem and its fix' =>
  sub {
    my $report = _preflight(
        open     => $FD_OVER_RATIO,
        features => {
            reuseport => { setting => 'on', enabled => 0 },
            sendfile  => { setting => 'auto' },
        },
        reuseport => 0,
    )->report;

    is_deeply(
        [ split /\n/msx, _service('en')->findings($report)->human_text ],
        [
            "\N{CHECK MARK} host: Linux with epoll, 4 CPUs",
            "\N{CHECK MARK} web processes: 8 for 4 CPUs",
            '! open files: 81 of 100 in use, more than 80%',
            '    Fix: LimitNOFILE=100 in the service file'
              . ' (the units in deploy/systemd/ set it)',
            '         or ulimit -n 100 in the shell that starts GPForum',
            '! memory: swap is in use',
            q{    Fix: add memory, or lower GPFORUM_WEB_PROCESSES}
              . q{ in your shell's environment},
            '! reuseport: asked for, but this operating system cannot do it',
            q{    Fix: set GPFORUM_OS_REUSEPORT=auto}
              . q{ in your shell's environment},
            q{},
            '3 things to fix.',
        ],
        'in English: the passing host and processes, then the problems'
    );
    is_deeply(
        [ split /\n/msx, _service('it')->findings($report)->human_text ],
        [
            "\N{CHECK MARK} host: Linux con epoll, 4 CPU",
            "\N{CHECK MARK} processi web: 8 per 4 CPU",
            q{! file aperti: 81 su 100 in uso, oltre l'80%},
            '    Rimedio: LimitNOFILE=100 nel file del servizio'
              . q{ (le unit}
              . "\N{LATIN SMALL LETTER A WITH GRAVE}"
              . ' in deploy/systemd/ lo impostano)',
            '             oppure ulimit -n 100 nella shell che avvia GPForum',
            "! memoria: lo swap \N{LATIN SMALL LETTER E WITH GRAVE} in uso",
            '    Rimedio: aggiungi memoria, oppure abbassa'
              . q{ GPFORUM_WEB_PROCESSES nell'ambiente della shell},
            '! reuseport: richiesto, ma questo sistema operativo non lo'
              . ' supporta',
            '    Rimedio: imposta GPFORUM_OS_REUSEPORT=auto'
              . q{ nell'ambiente della shell},
            q{},
            '3 cose da sistemare.',
        ],
        'and in Italian, each fix under the first past "Rimedio: "'
    );

    my $deployed = GPForum::Service::Operations::OSPreflight->new(
        host => GPForum::Service::Operations::Host->new(
            catalog     => _catalog('en'),
            environment => 'production',
            os          => GPForum::OS->from_name('freebsd'),
        )
    );
    my $file = quotemeta '/usr/local/etc/gpforum/gpforum.env';
    like(
        $deployed->findings($report)->human_text,
        qr/GPFORUM_OS_REUSEPORT=auto [ ] in [ ] $file$/msx,
        'deployed, a fix names the file the service reads on that host'
    );
    is_deeply(
        $deployed->findings($report)->problem_lines('os-preflight: ')->[0],
        'os-preflight: ! open files: 81 of 100 in use, more than 80%',
        'and a journal line carries the program that wrote it'
    );
  };

subtest 'a check that fails stops the start, and its host line says why' =>
  sub {
    my $report = GPForum::OS::Preflight->new(
        profile => {
            web_processes => 1,
            os            => { name => 'linux', event_backend => 'epoll' },
            os_features   => {},
            os_sockets    => { keepalive => {} },
            os_processes  => { classes   => {} },
        }
    )->report;
    my $findings = _service('en')->findings($report);

    is( $findings->status,      'fail', 'no CPU count is a failure' );
    is( $findings->exit_status, 1,      'which a start does not survive' );
    like(
        $findings->human_text,
qr/^\N{BALLOT X} [ ] CPUs: [ ] they [ ] could [ ] not [ ] be [ ] counted$/msx,
        'and the line says what could not be read'
    );
    unlike( $findings->human_text, qr/host:/msx,
        'in place of the host line it would have made' );
  };

done_testing();

sub _preflight (%input) {
    my %given = (
        open      => 1,
        limit     => $FD_LIMIT,
        floor     => $FD_LIMIT,
        max_open  => $FD_LIMIT,
        features  => {},
        reuseport => 1,
        sendfile  => 1,
        %input,
    );

    return GPForum::OS::Preflight->new(
        minimum_file_descriptor_limit => $given{floor},
        max_open_file_descriptors     => $given{max_open},
        profile                       => {
            web_processes      => $WEB_PROCESSES,
            worker_processes   => undef,
            realtime_processes => 1,
            os                 => {
                name                     => 'linux',
                event_backend            => 'epoll',
                cpu_count                => $CPU_COUNT,
                recommended_worker_count => $DEFAULT_WORKERS,
                supports_reuseport       => $given{reuseport},
                supports_sendfile        => $given{sendfile},
                resources                => {
                    open_file_descriptors => $given{open},
                    file_descriptor_limit => $given{limit},
                    swap_pressure         => { status => 'warning' },
                },
            },
            os_features => $given{features},
            os_sockets  => {
                keepalive => {
                    setting   => 'on',
                    supported => 1,
                    enabled   => 1,
                    degraded  => 0,
                },
                reuseport => { setting => 'auto', supported => 0 },
            },
            os_processes => {
                classes => {
                    mail_worker => {
                        nice_delta => $NICE_DELTA,
                        enabled    => 1,
                        action     => 'supervisor-nice',
                    },
                },
            },
        },
    );
}

sub _catalog ($language) {
    return GPForum::Service::I18N::CliCatalog->new( language => $language );
}

# The findings of a host in development, where a fix names the shell.
sub _service ($language) {
    return GPForum::Service::Operations::OSPreflight->new(
        host => GPForum::Service::Operations::Host->new(
            catalog     => _catalog($language),
            environment => 'development',
        )
    );
}

sub _check ( $name, %input ) {
    return _named( _preflight(%input)->report, $name );
}

sub _named ( $report, $name ) {
    my ($check) = grep { $_->{name} eq $name } @{ $report->{checks} };

    return $check;
}

1;
