package GPForum::OS::RuntimePolicy;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $STATUS_OK       => 'ok';
const my $STATUS_DEGRADED => 'degraded';
const my $POLICY_CAP_CPU  => 'cap-to-cpu';
const my $MIN_BACKLOG     => 64;

has config  => undef;
has runtime => undef;

sub hypnotoad_config {
    my ($self) = @_;

    return {
        listen             => $self->_listen_locations,
        workers            => $self->_effective_web_processes,
        spare              => $self->config->runtime_spare_processes,
        clients            => $self->config->runtime_clients,
        backlog            => $self->config->runtime_backlog,
        requests           => $self->config->runtime_requests,
        keep_alive_timeout => $self->config->runtime_keep_alive,
        inactivity_timeout => $self->config->runtime_inactivity,
        graceful_timeout   => $self->config->runtime_graceful_timeout,
        heartbeat_interval => $self->config->runtime_heartbeat_interval,
        heartbeat_timeout  => $self->config->runtime_heartbeat_timeout,
        upgrade_timeout    => $self->config->runtime_upgrade_timeout,
        proxy              => $self->config->runtime_proxy ? 1 : 0,
        pid_file           => $self->config->runtime_pid_file,
    };
}

sub report {
    my ($self) = @_;

    my $hypnotoad = $self->hypnotoad_config;
    my @checks    = $self->_checks($hypnotoad);

    return {
        status            => _overall_status( \@checks ),
        checks            => \@checks,
        hypnotoad         => $hypnotoad,
        effective         => $self->_effective_runtime,
        degraded_features => $self->_degraded_features,
        socket_runtime    => $self->_socket_runtime,
        backlog           => $self->_backlog_report($hypnotoad),
        static_transfer   => $self->_static_transfer_report,
    };
}

sub readiness_check {
    my ($self) = @_;

    my $report = $self->report;
    return {
        name   => 'runtime_enforcement',
        status => $report->{status},
        report => $report,
    };
}

sub _checks {
    my ( $self, $hypnotoad ) = @_;

    return (
        $self->_worker_check($hypnotoad), $self->_backlog_check($hypnotoad),
        $self->_feature_check,            $self->_listen_check($hypnotoad),
    );
}

sub _effective_runtime {
    my ($self) = @_;

    return {
        configured_web_processes => $self->runtime->web_processes,
        effective_web_processes  => $self->_effective_web_processes,
        worker_policy            => $self->config->runtime_worker_policy,
        cpu_count                => $self->runtime->os_profile->cpu_count,
        max_web_per_cpu          => $self->config->runtime_max_web_per_cpu,
    };
}

sub _listen_locations {
    my ($self) = @_;

    return [ map { $self->_enforced_listen_location($_) }
          @{ $self->config->runtime_listen_locations } ];
}

sub _enforced_listen_location {
    my ( $self, $location ) = @_;

    return $location if !$self->_reuseport_enabled;
    return $location if !_can_add_reuseport($location);

    my $separator = index( $location, q{?} ) >= 0 ? q{&} : q{?};
    return $location . $separator . 'reuse=1';
}

sub _effective_web_processes {
    my ($self) = @_;

    my $configured = $self->runtime->web_processes;
    return $configured
      if $self->config->runtime_worker_policy ne $POLICY_CAP_CPU;

    my $cap =
      $self->runtime->os_profile->cpu_count *
      $self->config->runtime_max_web_per_cpu;
    return $configured <= $cap ? $configured : $cap;
}

sub _reuseport_enabled {
    my ($self) = @_;

    return $self->_socket_snapshot->{reuseport}{enabled} ? 1 : 0;
}

sub _socket_snapshot {
    my ($self) = @_;

    return $self->runtime->os_profile->socket_snapshot(
        $self->runtime->os_feature_settings );
}

sub _feature_snapshot {
    my ($self) = @_;

    return $self->runtime->os_profile->feature_snapshot(
        $self->runtime->os_feature_settings );
}

sub _worker_check {
    my ( $self, $hypnotoad ) = @_;

    return _degraded_check( 'worker_count',
        'configured web process count was capped to CPU policy' )
      if $hypnotoad->{workers} < $self->runtime->web_processes;

    return _ok_check('worker_count');
}

sub _backlog_check {
    my ( $self, $hypnotoad ) = @_;

    return _degraded_check( 'backlog',
        'configured listen backlog is below conservative deployment floor' )
      if $hypnotoad->{backlog} < $MIN_BACKLOG;

    return _ok_check('backlog');
}

sub _feature_check {
    my ($self) = @_;

    return _degraded_check( 'features',
        'one or more requested socket features are unsupported' )
      if @{ $self->_degraded_features };

    return _ok_check('features');
}

sub _listen_check {
    my ( $self, $hypnotoad ) = @_;

    return _degraded_check( 'listen', 'no listen locations configured' )
      if !@{ $hypnotoad->{listen} };

    return _ok_check('listen');
}

sub _degraded_features {
    my ($self) = @_;

    my $sockets = $self->_socket_snapshot;
    return [
        grep { $sockets->{$_}{degraded} }
        sort keys %{$sockets}
    ];
}

sub _socket_runtime {
    my ($self) = @_;

    my $sockets = $self->_socket_snapshot;
    return {
        reuseport   => _socket_runtime_entry( $sockets, 'reuseport' ),
        keepalive   => _socket_runtime_entry( $sockets, 'keepalive' ),
        tcp_nodelay => {
            %{ _socket_runtime_entry( $sockets, 'tcp_nodelay' ) },
            enforcement => 'mojolicious-ioloop',
        },
    };
}

sub _backlog_report {
    my ( $self, $hypnotoad ) = @_;

    return {
        configured => $hypnotoad->{backlog},
        saturation => {
            available => 0,
            reason    => 'portable listen queue saturation is not exposed',
        },
    };
}

sub _static_transfer_report {
    my ($self) = @_;

    my $sockets   = $self->_socket_snapshot;
    my $features  = $self->_feature_snapshot;
    my $xsendfile = $features->{static_xsendfile}{enabled} ? 1 : 0;
    my $mode =
      $sockets->{sendfile}{enabled} || $xsendfile
      ? 'delegated'
      : 'perl-fallback';

    return {
        mode      => $mode,
        sendfile  => $sockets->{sendfile},
        xsendfile => $xsendfile,
        boundary  => 'reverse-proxy-or-web-server',
    };
}

sub _socket_runtime_entry {
    my ( $sockets, $name ) = @_;

    return {
        supported   => $sockets->{$name}{supported},
        enabled     => $sockets->{$name}{enabled},
        degraded    => $sockets->{$name}{degraded},
        setting     => $sockets->{$name}{setting},
        enforcement => 'hypnotoad-config',
    };
}

sub _can_add_reuseport {
    my ($location) = @_;

    return 0 if $location =~ /\A http[+]unix: /msx;
    return 0 if $location =~ / (?: [?&] fd= | [?&] reuse= ) /msx;

    return 1;
}

sub _overall_status {
    my ($checks) = @_;

    for my $check ( @{$checks} ) {
        return $STATUS_DEGRADED if $check->{status} eq $STATUS_DEGRADED;
    }

    return $STATUS_OK;
}

sub _ok_check {
    my ($name) = @_;

    return { name => $name, status => $STATUS_OK };
}

sub _degraded_check {
    my ( $name, $reason ) = @_;

    return {
        name   => $name,
        status => $STATUS_DEGRADED,
        reason => $reason,
    };
}

1;
