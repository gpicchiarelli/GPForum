# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;
use Test::Mojo;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::OS::Base;
use GPForum::OS::Linux;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Operations::Readiness;
use GPForum::Test::OSResourceSnapshot;
use GPForum::Test::OSTinyLinux;
use GPForum::Test::OperationsClock;
use GPForum::Test::ReadinessSchema;

our $VERSION = '0.001';

const my $WEB_PROCESSES       => 6;
const my $EXPECTED_WEB_CAP    => 2;
const my $LOW_BACKLOG         => 16;
const my $CONFIGURED_BACKLOG  => 256;
const my $CONFIGURED_CLIENTS  => 75;
const my $CONFIGURED_REQUESTS => 120;

my $resource = GPForum::Test::OSResourceSnapshot->new;
my $config   = GPForum::Config->new(
    web_processes           => $WEB_PROCESSES,
    runtime_listen          => 'http://*:9000',
    runtime_backlog         => $CONFIGURED_BACKLOG,
    runtime_clients         => $CONFIGURED_CLIENTS,
    runtime_requests        => $CONFIGURED_REQUESTS,
    runtime_worker_policy   => 'cap-to-cpu',
    os_reuseport            => 'auto',
    os_sendfile             => 'auto',
    os_static_xsendfile     => 'auto',
    os_worker_priority      => 'off',
    runtime_max_web_per_cpu => 2,
);
$config->validate;

my $runtime = GPForum::Runtime->new(
    web_processes      => $WEB_PROCESSES,
    worker_processes   => 1,
    realtime_processes => 1,
    os_profile         => GPForum::Test::OSTinyLinux->new(
        resource_probe => $resource,
    ),
    os_feature_settings => $config->os_feature_settings,
);
my $policy = GPForum::OS::RuntimePolicy->new(
    config  => $config,
    runtime => $runtime,
);
my $hypnotoad = $policy->hypnotoad_config;

is( $hypnotoad->{workers},
    $EXPECTED_WEB_CAP, 'runtime policy caps workers to CPU policy' );
is_deeply(
    $hypnotoad->{trusted_proxies},
    [ '127.0.0.1', '::1' ],
    'X-Forwarded-For is believed from the loopback only, by default'
);
is( $hypnotoad->{listen}[0],
    'http://*:9000?reuse=1', 'runtime policy enables reuseport in listen URL' );
is( $hypnotoad->{backlog},
    $CONFIGURED_BACKLOG, 'runtime policy applies configured backlog' );
is( $hypnotoad->{clients},
    $CONFIGURED_CLIENTS, 'runtime policy applies configured client budget' );
is( $hypnotoad->{requests},
    $CONFIGURED_REQUESTS, 'runtime policy applies keep-alive request budget' );
is( $policy->report->{status},
    'degraded', 'worker capping is reported as degraded posture' );
is( $policy->report->{static_transfer}{mode},
    'delegated', 'sendfile-capable runtime reports delegated static transfer' );
ok(
    exists $policy->report->{backlog}{saturation},
    'runtime policy reports backlog saturation availability'
);

my $configured_policy = GPForum::OS::RuntimePolicy->new(
    config => GPForum::Config->new(
        web_processes         => $WEB_PROCESSES,
        runtime_worker_policy => 'configured',
        runtime_listen        => 'http://*:9000',
    ),
    runtime => $runtime,
);
is( $configured_policy->hypnotoad_config->{workers},
    $WEB_PROCESSES, 'configured worker policy preserves requested workers' );

my $unknown_config = GPForum::Config->new(
    runtime_listen      => 'http://*:9000',
    os_reuseport        => 'on',
    os_sendfile         => 'on',
    os_static_xsendfile => 'on',
);
my $unknown_runtime = GPForum::Runtime->new(
    os_profile => GPForum::OS::Base->new( resource_probe => $resource ),
    os_feature_settings => $unknown_config->os_feature_settings,
);
my $unknown_policy = GPForum::OS::RuntimePolicy->new(
    config  => $unknown_config,
    runtime => $unknown_runtime,
);
is( $unknown_policy->hypnotoad_config->{listen}[0],
    'http://*:9000', 'unsupported reuseport is not applied to listen URL' );
is( $unknown_policy->report->{status},
    'degraded', 'unsupported requested runtime feature degrades policy' );

my $low_backlog_policy = GPForum::OS::RuntimePolicy->new(
    config => GPForum::Config->new(
        runtime_listen  => 'http://*:9000',
        runtime_backlog => $LOW_BACKLOG,
    ),
    runtime => GPForum::Runtime->new(
        os_profile => GPForum::OS::Linux->new( resource_probe => $resource ),
        os_feature_settings => _default_features(),
    ),
);
ok( _has_check_status( $low_backlog_policy->report, 'backlog', 'degraded' ),
    'low backlog creates runtime enforcement warning' );

my $metrics = GPForum::Service::Operations::MetricsSnapshot->new(
    clock          => GPForum::Test::OperationsClock->new,
    runtime        => $runtime,
    runtime_policy => $policy,
)->collect;
is( $metrics->{runtime_enforcement}{hypnotoad}{workers},
    $EXPECTED_WEB_CAP, 'metrics expose effective runtime worker count' );

my $ready = GPForum::Service::Operations::Readiness->new(
    environment    => 'test',
    runtime        => $runtime,
    runtime_policy => $policy,
    schema         => GPForum::Test::ReadinessSchema->new,
)->check;
is( $ready->{status},
    'degraded', 'readiness reports degraded runtime enforcement posture' );

my $test = Test::Mojo->new('GPForum');
ok( exists $test->app->config->{hypnotoad},
    'application startup installs Hypnotoad runtime config' );
ok(
    exists $test->app->config->{gpforum_runtime_enforcement},
    'application startup exposes runtime enforcement report'
);

done_testing();

sub _default_features {
    return {
        reuseport        => 'auto',
        sendfile         => 'auto',
        static_xsendfile => 'auto',
        worker_priority  => 'off',
        affinity         => 'off',
    };
}

sub _has_check_status {
    my ( $report, $name, $status ) = @_;

    for my $check ( @{ $report->{checks} } ) {
        return 1
          if $check->{name} eq $name && $check->{status} eq $status;
    }

    return 0;
}

1;
