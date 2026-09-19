package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::OS;
use GPForum::OS::Process;
use GPForum::OS::Resource;
use GPForum::OS::Socket;
use GPForum::Runtime;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Test::OperationsClock;

our $VERSION = '0.001';

const my $EXPECTED_TESTS         => 54;
const my $WEB_PROCESSES          => 2;
const my $MAINTENANCE_NICE_DELTA => 10;

plan tests => $EXPECTED_TESTS;

my $detected        = GPForum::OS->detect;
my %allowed_os_name = map { $_ => 1 } qw(darwin freebsd linux unknown);
ok( $allowed_os_name{ $detected->name },
    'OS detection returns an allowed platform name' );
ok( $detected->cpu_count >= 1, 'OS profile reports a positive CPU count' );
ok(
    $detected->recommended_worker_count >= 1,
    'OS profile recommends a positive worker count'
);
ok(
    exists $detected->snapshot->{resources},
    'OS snapshot includes resource snapshot'
);
ok(
    exists $detected->snapshot->{sockets},
    'OS snapshot includes socket policy snapshot'
);
ok(
    exists $detected->snapshot->{processes},
    'OS snapshot includes process policy snapshot'
);

my $unknown = GPForum::OS->from_name('plan9');
is( $unknown->name, 'unknown', 'unknown OS uses conservative profile' );
ok( !$unknown->supports_reuseport,
    'unknown OS does not assume SO_REUSEPORT support' );
ok( !$unknown->supports_sendfile,
    'unknown OS does not assume sendfile support' );
is( $unknown->event_backend, 'select', 'unknown OS falls back to select' );
ok(
    !$unknown->feature_enabled( 'reuseport', 'auto' ),
    'auto reuseport is disabled for unknown OS'
);
ok( $unknown->feature_enabled( 'reuseport', 'on' ),
    'explicit on enables feature flag' );
ok( !$unknown->feature_enabled( 'reuseport', 'off' ),
    'explicit off disables feature flag' );
my $unknown_features = $unknown->feature_snapshot(
    {
        reuseport        => 'on',
        sendfile         => 'off',
        worker_priority  => 'auto',
        static_xsendfile => 'auto',
        affinity         => 'manual',
    }
);
ok(
    $unknown_features->{reuseport}{enabled},
    'explicit reuseport on enables effective feature'
);
ok(
    !$unknown_features->{sendfile}{enabled},
    'explicit sendfile off disables effective feature'
);
ok(
    !$unknown_features->{worker_priority}{enabled},
    'unknown OS does not enable worker priority automatically'
);
ok( $unknown_features->{affinity}{enabled},
    'manual affinity is exposed as enabled deployment control' );
ok(
    !$unknown->socket_snapshot( { reuseport => 'on' } )->{reuseport}{enabled},
    'unknown OS does not enable unsupported reuseport socket'
);
ok( $unknown->socket_snapshot( { reuseport => 'on' } )->{reuseport}{degraded},
    'unsupported explicit socket feature is marked degraded' );

my $darwin = GPForum::OS->from_name('darwin');
is( $darwin->name,          'darwin', 'Darwin profile is selectable' );
is( $darwin->event_backend, 'kqueue', 'Darwin profile declares kqueue' );
ok( $darwin->supports_reuseport, 'Darwin profile supports reuseport' );
ok( $darwin->supports_sendfile,  'Darwin profile supports sendfile' );

my $freebsd = GPForum::OS->from_name('freebsd');
is( $freebsd->name,          'freebsd', 'FreeBSD profile is selectable' );
is( $freebsd->event_backend, 'kqueue',  'FreeBSD profile declares kqueue' );
ok( $freebsd->supports_reuseport, 'FreeBSD profile supports reuseport' );
ok( $freebsd->supports_sendfile,  'FreeBSD profile supports sendfile' );

my $linux = GPForum::OS->from_name('linux');
is( $linux->name,          'linux', 'Linux profile is selectable' );
is( $linux->event_backend, 'epoll', 'Linux profile declares epoll' );
ok( $linux->supports_reuseport, 'Linux profile supports reuseport' );
ok( $linux->supports_sendfile,  'Linux profile supports sendfile' );

my $runtime = GPForum::Runtime->new(
    web_processes       => $WEB_PROCESSES,
    worker_processes    => 1,
    realtime_processes  => 1,
    os_profile          => $linux,
    os_feature_settings => {
        reuseport        => 'auto',
        sendfile         => 'off',
        worker_priority  => 'off',
        static_xsendfile => 'auto',
        affinity         => 'off',
    },
);
my $runtime_hash = $runtime->as_hash;
is( $runtime_hash->{os}{name}, 'linux', 'runtime hash includes OS profile' );
is( $runtime_hash->{os}{event_backend},
    'epoll', 'runtime hash includes event backend' );
is( $runtime_hash->{os_features}{sendfile}{setting},
    'off', 'runtime hash includes OS feature setting' );
ok(
    exists $runtime_hash->{os_sockets}{reuseaddr},
    'runtime hash includes socket policy'
);
ok( exists $runtime_hash->{os_processes}{classes}{web_worker},
    'runtime hash includes process class policy' );
is( $runtime_hash->{os_processes}{classes}{maintenance_worker}{action},
    'observe', 'disabled worker priority remains descriptive' );

my $metrics = GPForum::Service::Operations::MetricsSnapshot->new(
    clock   => GPForum::Test::OperationsClock->new,
    runtime => $runtime,
)->collect;
is( $metrics->{os}{name}, 'linux', 'metrics expose OS profile' );
is( $metrics->{os}{supports_sendfile},
    1, 'metrics expose OS sendfile capability' );
ok( exists $metrics->{os}{resources}, 'metrics expose OS resource snapshot' );
is( $metrics->{os_features}{sendfile}{enabled},
    0, 'metrics expose effective OS feature state' );
ok(
    exists $metrics->{os}{resources}{open_file_descriptors},
    'metrics expose open file descriptor count key'
);
ok(
    exists $metrics->{os_sockets}{tcp_nodelay},
    'metrics expose socket policy snapshot'
);
ok( exists $metrics->{os_processes}{classes}{projection_worker},
    'metrics expose process class policy' );

my $resources = GPForum::OS::Resource->new->snapshot;
ok(
    exists $resources->{open_file_descriptors},
    'resource probe returns file descriptor key'
);

my $socket_policy = GPForum::OS::Socket->new->snapshot(
    $linux,
    {
        reuseport => { enabled => 1 },
        sendfile  => { enabled => 1 },
    }
);
ok( $socket_policy->{reuseaddr}{enabled}, 'socket policy enables reuseaddr' );
ok(
    $socket_policy->{reuseport}{enabled},
    'socket policy enables supported reuseport'
);
ok( $socket_policy->{keepalive}{enabled}, 'socket policy enables keepalive' );
ok(
    $socket_policy->{tcp_nodelay}{enabled},
    'socket policy enables tcp_nodelay'
);
ok(
    $socket_policy->{sendfile}{enabled},
    'socket policy enables supported sendfile'
);

my $process_policy = GPForum::OS::Process->new;
my $process_plan   = $process_policy->priority_plan( 'maintenance_worker',
    { worker_priority => { enabled => 1 } } );
is( $process_plan->{nice_delta},
    $MAINTENANCE_NICE_DELTA,
    'maintenance worker receives lower scheduling priority plan' );
is( $process_plan->{action},
    'setpriority-if-permitted',
    'enabled worker priority plans setpriority action' );
my $unknown_process_plan = $process_policy->priority_plan( 'custom_worker',
    { worker_priority => { enabled => 0 } } );
ok( !$unknown_process_plan->{known},
    'unknown process class is reported explicitly' );
is( $unknown_process_plan->{nice_delta},
    0, 'unknown process class uses neutral nice delta' );

1;
