# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;
use GPForum::Test::RuntimePolicyProfile;

our $VERSION = '0.001';

# The whole report OS::RuntimePolicy builds, and the listen locations it
# hands Hypnotoad, read against an OS profile whose snapshots the test
# chooses, so every part is pinned rather than only what t/53's host shows.

const my $CPUS          => 2;
const my $PER_CPU       => 3;
const my $CAPPED        => 6;
const my $CONFIGURED    => 9;
const my $LOW_BACKLOG   => 63;
const my $FLOOR_BACKLOG => 64;
const my %SETTINGS      => ( reuseport => 'on', sendfile => 'auto' );

subtest 'every part of the report, on a host that degrades' => sub {
    my $profile = _profile(
        reuseport => 1,
        sendfile  => 0,
        degraded  => [qw(tcp_nodelay keepalive)],
    );
    my $policy = _policy(
        $profile,
        runtime_backlog       => $LOW_BACKLOG,
        runtime_worker_policy => 'cap-to-cpu',
    );
    my $report = $policy->report;

    is( $report->{status}, 'degraded', 'any degraded check degrades it' );
    is_deeply(
        $report->{checks},
        [
            {
                name   => 'worker_count',
                status => 'degraded',
                reason =>
                  'configured web process count was capped to CPU policy',
            },
            {
                name   => 'backlog',
                status => 'degraded',
                reason => 'configured listen backlog is below conservative'
                  . ' deployment floor',
            },
            {
                name   => 'features',
                status => 'degraded',
                reason =>
                  'one or more requested socket features are unsupported',
            },
            { name => 'listen', status => 'ok' },
        ],
        'the four checks, in order, each with its reason'
    );
    is_deeply( $report->{hypnotoad}, $policy->hypnotoad_config,
        'the Hypnotoad configuration is the one handed to Hypnotoad' );
    is( $report->{hypnotoad}{workers}, $CAPPED, 'capped to CPUs times 3' );
    is_deeply(
        $report->{effective},
        {
            configured_web_processes => $CONFIGURED,
            effective_web_processes  => $CAPPED,
            worker_policy            => 'cap-to-cpu',
            cpu_count                => $CPUS,
            max_web_per_cpu          => $PER_CPU,
        },
        'the effective runtime'
    );
    is_deeply(
        $report->{degraded_features},
        [qw(keepalive tcp_nodelay)],
        'the degraded socket features, sorted'
    );
    is_deeply(
        $report->{socket_runtime},
        {
            reuseport   => _entry( $profile, 'reuseport' ),
            keepalive   => _entry( $profile, 'keepalive' ),
            tcp_nodelay => {
                %{ _entry( $profile, 'tcp_nodelay' ) },
                enforcement => 'mojolicious-ioloop'
            },
        },
        'the socket runtime, TCP_NODELAY enforced by the IOLoop'
    );
    is_deeply(
        $report->{backlog},
        {
            configured => $LOW_BACKLOG,
            saturation => {
                available => 0,
                reason    => 'portable listen queue saturation is not exposed',
            },
        },
        'the backlog'
    );
    is_deeply(
        $report->{static_transfer},
        {
            mode      => 'perl-fallback',
            sendfile  => $profile->sockets->{sendfile},
            xsendfile => 0,
            boundary  => 'reverse-proxy-or-web-server',
        },
        'no sendfile and no X-Sendfile fall back to Perl'
    );
    is_deeply( [ grep { ref ne 'HASH' || !%{$_} } @{ $profile->asked } ],
        [], 'every snapshot is asked with the runtime feature settings' );
};

subtest 'a host that degrades nothing' => sub {
    my $policy = _policy(
        _profile( reuseport => 0, sendfile => 1 ),
        runtime_backlog       => $FLOOR_BACKLOG,
        runtime_worker_policy => 'configured',
    );
    my $report = $policy->report;

    is( $report->{status}, 'ok', 'all checks ok' );
    is_deeply( [ map { $_->{status} } @{ $report->{checks} } ],
        [qw(ok ok ok ok)], 'the backlog floor itself is ok' );
    is( $report->{hypnotoad}{workers},
        $CONFIGURED, 'the configured policy keeps the configured count' );
    is( $report->{static_transfer}{mode},
        'delegated', 'sendfile delegates static transfer' );
};

subtest 'X-Sendfile alone delegates too' => sub {
    my $profile = _profile( reuseport => 0, sendfile => 0 );
    $profile->features->{static_xsendfile}{enabled} = 1;
    my $transfer = _policy($profile)->report->{static_transfer};

    is( $transfer->{mode},      'delegated', 'delegated' );
    is( $transfer->{xsendfile}, 1,           'and says X-Sendfile is on' );
};

subtest 'no listen location is a degraded check' => sub {
    my $report =
      _policy( _profile( reuseport => 1 ), runtime_listen => q{} )->report;

    is_deeply(
        $report->{checks}[-1],
        {
            name   => 'listen',
            status => 'degraded',
            reason => 'no listen locations configured',
        },
        'listen is degraded'
    );
};

subtest 'reuse=1 is added only where it can be' => sub {
    my $listen = join q{,}, 'http://*:8080', 'http://*:8081?x=1',
      'http+unix://%2Ftmp%2Fgp.sock', 'http://*:8082?fd=3',
      'http://*:8083?reuse=0',        'https://*:8443?cert=/c.pem&reuse=0';

    is_deeply(
        _policy( _profile( reuseport => 1 ), runtime_listen => $listen )
          ->hypnotoad_config->{listen},
        [
            'http://*:8080?reuse=1',
            'http://*:8081?x=1&reuse=1',
            'http+unix://%2Ftmp%2Fgp.sock',
            'http://*:8082?fd=3',
            'http://*:8083?reuse=0',
            'https://*:8443?cert=/c.pem&reuse=0',
        ],
        'not on a UNIX socket, an inherited descriptor or a reuse already set'
    );
    is_deeply(
        _policy( _profile( reuseport => 0 ), runtime_listen => $listen )
          ->hypnotoad_config->{listen},
        [ split /,/msx, $listen ],
        'and nowhere when SO_REUSEPORT is off'
    );
};

done_testing();

sub _policy ( $profile, %config ) {
    my $config = GPForum::Config->new(
        runtime_listen          => 'http://*:8080',
        runtime_max_web_per_cpu => $PER_CPU,
        %config,
    );

    return GPForum::OS::RuntimePolicy->new(
        config  => $config,
        runtime => GPForum::Runtime->new(
            web_processes       => $CONFIGURED,
            os_profile          => $profile,
            os_feature_settings => {%SETTINGS},
        ),
    );
}

sub _profile (%host) {
    my %degraded = map { $_ => 1 } @{ $host{degraded} || [] };
    my %sockets  = map {
        $_ => {
            supported => $degraded{$_}        ? 0             : 1,
            enabled   => $host{$_}            ? 1             : 0,
            degraded  => $degraded{$_}        ? 1             : 0,
            setting   => exists $SETTINGS{$_} ? $SETTINGS{$_} : q{auto},
        }
    } qw(reuseport keepalive tcp_nodelay sendfile);

    return GPForum::Test::RuntimePolicyProfile->new(
        cpu_count => $CPUS,
        sockets   => \%sockets,
        features  => { static_xsendfile => { enabled => 0 } },
    );
}

sub _entry ( $profile, $name ) {
    my $socket = $profile->sockets->{$name};

    return {
        supported   => $socket->{supported},
        enabled     => $socket->{enabled},
        degraded    => $socket->{degraded},
        setting     => $socket->{setting},
        enforcement => 'hypnotoad-config',
    };
}

1;
