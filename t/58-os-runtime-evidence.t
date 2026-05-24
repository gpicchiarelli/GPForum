package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::OS::Base;
use GPForum::OS::RuntimeEvidence;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;
use GPForum::Test::OSResourceSnapshot;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 25;
const my $WORKERS        => 2;

plan tests => $EXPECTED_TESTS;

my $config = GPForum::Config->new(
    runtime_listen        => 'http://127.0.0.1:5555',
    runtime_worker_policy => 'configured',
    web_processes         => $WORKERS,
    os_reuseport          => 'auto',
    os_sendfile           => 'auto',
    os_static_xsendfile   => 'auto',
);
$config->validate;

my $runtime = GPForum::Runtime->new(
    web_processes      => $WORKERS,
    worker_processes   => 1,
    realtime_processes => 1,
    os_profile         => GPForum::OS::Base->new(
        resource_probe => GPForum::Test::OSResourceSnapshot->new,
    ),
    os_feature_settings => $config->os_feature_settings,
);
my $policy = GPForum::OS::RuntimePolicy->new(
    config  => $config,
    runtime => $runtime,
);
my $evidence = GPForum::OS::RuntimeEvidence->new(
    config         => $config,
    runtime        => $runtime,
    runtime_policy => $policy,
    dbh            => GPForum::Test::RuntimeEvidenceDbh->new,
    tempfile_dir   => '/tmp',
)->report;

is( $evidence->{status}, 'active', 'OS evidence is active for select profile' );
is( $evidence->{event_loop}{declared_backend},
    'select', 'evidence records declared backend' );
like(
    $evidence->{event_loop}{actual_reactor_class},
    qr/\A Mojo::Reactor::/msx,
    'evidence records actual reactor class'
);
is( $evidence->{hypnotoad}{prefork}, 1, 'evidence records prefork workers' );
is( $evidence->{hypnotoad}{workers},
    $WORKERS, 'evidence records worker count' );
is( $evidence->{hypnotoad}{reuseport_configured},
    0, 'unknown OS profile does not configure reuseport' );
is( $evidence->{hypnotoad}{backlog},
    $config->runtime_backlog, 'evidence records backlog' );
is(
    $evidence->{hypnotoad}{keep_alive_timeout},
    $config->runtime_keep_alive,
    'evidence records keep-alive timeout'
);

for my $name (qw(reuseaddr reuseport keepalive tcp_nodelay)) {
    ok(
        exists $evidence->{socket_options}{$name},
        "evidence records $name socket option"
    );
    ok(
        exists $evidence->{socket_options}{$name}{status},
        "evidence records $name socket status"
    );
}

is( $evidence->{static_transfer}{status},
    'unavailable', 'unknown OS profile keeps static transfer unavailable' );
is( $evidence->{static_transfer}{materialized_in_benchmark},
    0, 'sendfile is not materialized by benchmark' );
is( $evidence->{static_transfer}{xsendfile_header_implemented},
    0, 'X-Sendfile is explicitly not implemented yet' );

is( $evidence->{postgresql}{available},
    1, 'evidence reads PostgreSQL settings from dbh' );
is( $evidence->{postgresql}{settings}{shared_buffers}{setting},
    '16384', 'evidence records shared_buffers' );
is( $evidence->{postgresql}{applied_by_gpforum},
    0, 'PostgreSQL tuning is not applied by GPForum runtime' );

is( $evidence->{filesystem}{status},
    'active', 'evidence records temporary filesystem status' );
is( $evidence->{filesystem}{temp_path},
    '/tmp', 'evidence uses injected temp path in tests' );

my $no_db = GPForum::OS::RuntimeEvidence->new(
    config         => $config,
    runtime        => $runtime,
    runtime_policy => $policy,
    dbh            => GPForum::Test::RuntimeEvidenceFailingDbh->new,
    tempfile_dir   => '/tmp',
)->report;
is( $no_db->{postgresql}{available},
    0, 'evidence tolerates unavailable PostgreSQL settings' );

1;

package GPForum::Test::RuntimeEvidenceFailingDbh;

use strict;
use warnings;

use Mojo::Base -base;

sub selectall_arrayref {
    die 'pg_settings unavailable';
}

1;

package GPForum::Test::RuntimeEvidenceDbh;

use strict;
use warnings;

use Mojo::Base -base;

sub selectall_arrayref {
    my ( $self, $sql, $attributes, @settings ) = @_;

    return [
        map {
            {
                name    => $_,
                setting => $_ eq 'shared_buffers' ? '16384' : '1',
                unit    => $_ eq 'shared_buffers' ? '8kB'   : undef,
                source  => 'test',
            }
        } @settings
    ];
}

1;
