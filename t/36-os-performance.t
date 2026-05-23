package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::OS;
use GPForum::OS::Resource;
use GPForum::Runtime;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Test::OperationsClock;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 30;
const my $WEB_PROCESSES  => 2;

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
    web_processes      => $WEB_PROCESSES,
    worker_processes   => 1,
    realtime_processes => 1,
    os_profile         => $linux,
);
my $runtime_hash = $runtime->as_hash;
is( $runtime_hash->{os}{name}, 'linux', 'runtime hash includes OS profile' );
is( $runtime_hash->{os}{event_backend},
    'epoll', 'runtime hash includes event backend' );

my $metrics = GPForum::Service::Operations::MetricsSnapshot->new(
    clock   => GPForum::Test::OperationsClock->new,
    runtime => $runtime,
)->collect;
is( $metrics->{os}{name}, 'linux', 'metrics expose OS profile' );
is( $metrics->{os}{supports_sendfile},
    1, 'metrics expose OS sendfile capability' );
ok( exists $metrics->{os}{resources}, 'metrics expose OS resource snapshot' );
ok(
    exists $metrics->{os}{resources}{open_file_descriptors},
    'metrics expose open file descriptor count key'
);

my $resources = GPForum::OS::Resource->new->snapshot;
ok(
    exists $resources->{open_file_descriptors},
    'resource probe returns file descriptor key'
);

1;
