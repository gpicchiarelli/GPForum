package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::OS::Base;
use GPForum::OS::Darwin;
use GPForum::OS::FreeBSD;
use GPForum::OS::Linux;
use GPForum::OS::Preflight;
use GPForum::Runtime;
use GPForum::Test::OSResourceSnapshot;
use GPForum::Test::OSTinyLinux;

our $VERSION = '0.001';

const my $PRODUCTION_NOFILE_FLOOR => 65_536;
const my $HIGH_NOFILE_LIMIT       => 131_072;

my $resource = GPForum::Test::OSResourceSnapshot->new;
my $linux    = GPForum::OS::Linux->new( resource_probe => $resource );
my $runtime  = _runtime_for_os(
    $linux,
    {
        reuseport        => 'auto',
        sendfile         => 'auto',
        worker_priority  => 'on',
        static_xsendfile => 'auto',
        affinity         => 'off',
    }
);
my $report = GPForum::OS::Preflight->from_runtime($runtime)->report;

is( $report->{status},            'ok',    'Linux OS preflight is healthy' );
is( $report->{os}{event_backend}, 'epoll', 'Linux declares epoll backend' );
is( $report->{resources}{file_descriptor_limit},
    $HIGH_NOFILE_LIMIT, 'preflight reports file descriptor limit' );
is( $report->{recommendations}{ulimit_nofile}{recommended_minimum},
    $PRODUCTION_NOFILE_FLOOR, 'preflight reports recommended ulimit floor' );
ok(
    $report->{sockets}{keepalive}{enabled},
    'preflight reports keepalive policy'
);
ok(
    $report->{sockets}{tcp_nodelay}{enabled},
    'preflight reports tcp_nodelay policy'
);
is( $report->{processes}{classes}{mail_worker}{action},
    'setpriority-if-permitted',
    'preflight reports enabled worker priority plan' );

my $darwin = GPForum::OS::Darwin->new( resource_probe => $resource );
is(
    GPForum::OS::Preflight->from_runtime( _runtime_for_os($darwin) )
      ->report->{os}{event_backend},
    'kqueue',
    'Darwin preflight declares kqueue'
);

my $freebsd = GPForum::OS::FreeBSD->new( resource_probe => $resource );
is(
    GPForum::OS::Preflight->from_runtime( _runtime_for_os($freebsd) )
      ->report->{os}{event_backend},
    'kqueue',
    'FreeBSD preflight declares kqueue'
);

my $unknown        = GPForum::OS::Base->new( resource_probe => $resource );
my $unknown_report = GPForum::OS::Preflight->from_runtime(
    _runtime_for_os(
        $unknown,
        {
            reuseport        => 'on',
            sendfile         => 'on',
            worker_priority  => 'auto',
            static_xsendfile => 'on',
            affinity         => 'off',
        }
    )
)->report;
is( $unknown_report->{status},
    'degraded', 'unknown OS preflight degrades conservatively' );
ok( _has_check_status( $unknown_report, 'os', 'degraded' ),
    'unknown OS produces degraded OS check' );
ok(
    _has_check_status( $unknown_report, 'features', 'degraded' ),
    'unsupported explicit feature produces degraded feature check'
);
ok(
    _has_check_status( $unknown_report, 'sockets', 'degraded' ),
    'unsupported explicit socket option produces degraded socket check'
);

my $off_report = GPForum::OS::Preflight->from_runtime(
    _runtime_for_os(
        $linux,
        {
            reuseport        => 'off',
            sendfile         => 'off',
            worker_priority  => 'off',
            static_xsendfile => 'off',
            affinity         => 'off',
        }
    )
)->report;
is( $off_report->{sockets}{reuseport}{enabled},
    0, 'reuseport off disables socket policy' );
is( $off_report->{sockets}{reuseport}{degraded},
    0, 'reuseport off does not degrade socket policy' );

my $low_fd_resource = GPForum::Test::OSResourceSnapshot->new(
    snapshot_data => {
        open_file_descriptors => 4,
        file_descriptor_limit => 64,
        swap_pressure         => {
            status => 'ok',
        },
    },
);
my $low_fd = GPForum::OS::Preflight->from_runtime(
    _runtime_for_os(
        GPForum::OS::Linux->new( resource_probe => $low_fd_resource )
    )
)->report;
is( $low_fd->{status},
    'degraded', 'low file descriptor limit degrades preflight' );
ok(
    _has_check_status( $low_fd, 'file_descriptor_limit', 'degraded' ),
    'low file descriptor limit is reported by a dedicated check'
);

my $swap_resource = GPForum::Test::OSResourceSnapshot->new(
    snapshot_data => {
        open_file_descriptors => 4,
        file_descriptor_limit => $HIGH_NOFILE_LIMIT,
        swap_pressure         => {
            status => 'high',
        },
    },
);
my $swap_report = GPForum::OS::Preflight->from_runtime(
    _runtime_for_os(
        GPForum::OS::Linux->new( resource_probe => $swap_resource )
    )
)->report;
ok( _has_check_status( $swap_report, 'swap_pressure', 'degraded' ),
    'high swap pressure degrades OS preflight' );

my $tiny_runtime = GPForum::Runtime->new(
    web_processes      => 3,
    worker_processes   => 1,
    realtime_processes => 1,
    os_profile         => GPForum::Test::OSTinyLinux->new(
        resource_probe => $resource,
    ),
    os_feature_settings => _default_feature_settings(),
);
my $tiny_report = GPForum::OS::Preflight->from_runtime($tiny_runtime)->report;
is( $tiny_report->{status},
    'degraded', 'too many web workers for CPU count degrades preflight' );
ok( _has_check_status( $tiny_report, 'web_processes', 'degraded' ),
    'web process count is checked explicitly' );

my $decoded =
  decode_json( GPForum::OS::Preflight->from_runtime($runtime)->as_json );
is( $decoded->{status},   'ok',    'JSON report includes stable status' );
is( $decoded->{os}{name}, 'linux', 'JSON report includes OS name' );

my $human = GPForum::OS::Preflight->from_runtime($runtime)->human_text;
like( $human, qr/GPForum [ ] OS [ ] preflight/msx, 'human report has title' );
like(
    $human,
    qr/check=os [ ] status=ok/msx,
    'human report includes check lines'
);

my $script_json   = _capture_command( 'script/gpforum-os-preflight', '--json' );
my $script_report = decode_json($script_json);
ok( $script_report->{os}{name}, 'script JSON reports detected OS name' );

my $script_human = _capture_command( 'script/gpforum-os-preflight', '--human' );
like(
    $script_human,
    qr/GPForum [ ] OS [ ] preflight/msx,
    'script human output reports preflight title'
);

done_testing();

sub _runtime_for_os {
    my ( $os, $features ) = @_;

    return GPForum::Runtime->new(
        web_processes       => 2,
        worker_processes    => 1,
        realtime_processes  => 1,
        os_profile          => $os,
        os_feature_settings => $features || _default_feature_settings(),
    );
}

sub _default_feature_settings {
    return {
        reuseport        => 'auto',
        sendfile         => 'auto',
        worker_priority  => 'off',
        static_xsendfile => 'auto',
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

sub _capture_command {
    my (@command) = @_;

    open my $handle, q{-|}, @command
      or croak 'failed to run command';

    my $captured = q{};
    while ( my $line = <$handle> ) {
        $captured .= $line;
    }

    close $handle
      or croak 'command failed';

    return $captured;
}

1;
