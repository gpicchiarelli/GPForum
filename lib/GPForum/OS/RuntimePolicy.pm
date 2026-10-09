# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::RuntimePolicy;

use Const::Fast;
use File::Spec ();
use List::Util qw(any);
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Runtime;

our $VERSION = '0.001';

const my $STATUS_OK       => 'ok';
const my $STATUS_DEGRADED => 'degraded';
const my $MIN_BACKLOG     => 64;

# A listen location that sets up its own socket: a UNIX socket, a descriptor
# inherited from a supervisor, or one that already says whether to reuse.
const my $OWN_SOCKET => qr{ \A http[+]unix: | [?&] (?: fd | reuse ) = }msx;

__PACKAGE__->requires(qw(config runtime));

# The directories systemd makes for the service (RuntimeDirectory=gpforum
# gives /run/gpforum), as it names them in RUNTIME_DIRECTORY: colon separated
# when the unit lists several. Unset under any other supervisor.
has runtime_directory => sub { return $ENV{RUNTIME_DIRECTORY}; };

# MOJO_MODE as the environment sets it. Nothing reads it any more; the units
# shipped until 2026-10-08 set it, and the current ones do not.
has mojo_mode => sub { return $ENV{MOJO_MODE}; };

# True under a systemd unit from before 2026-10-08 that is still installed
# after the code was upgraded: it has a runtime directory and sets MOJO_MODE.
# Its PIDFile= names the working directory, so the pid file stays there --
# moved to the runtime directory, systemd would wait for a file nobody writes
# and fail the start -- and the start logs a line saying to copy the unit
# again.
sub outdated_unit ($self) {
    return defined $self->_runtime_directory && defined $self->mojo_mode
      ? 1
      : 0;
}

# Hypnotoad's configuration. Each listen location asks for SO_REUSEPORT when
# the OS has it enabled, unless the location sets up its own socket.
sub hypnotoad_config ($self) {
    my $reuseport = $self->_socket_snapshot->{reuseport}{enabled};
    my @listen;
    for my $location ( @{ $self->config->runtime_listen_locations } ) {
        my $separator = index( $location, q{?} ) >= 0 ? q{&} : q{?};
        push @listen,
          $reuseport && $location !~ $OWN_SOCKET
          ? $location . $separator . 'reuse=1'
          : $location;
    }

    return {
        listen             => \@listen,
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
        trusted_proxies    => $self->config->runtime_trusted_proxy_list,
        pid_file           => $self->_pid_file,
    };
}

# The checks run against what Hypnotoad will be given, then the runtime as
# configured and as the OS supports it.
sub report ($self) {
    my $hypnotoad = $self->hypnotoad_config;
    my $runtime   = $self->runtime;
    my $sockets   = $self->_socket_snapshot;
    my @degraded_features =
      grep { $sockets->{$_}{degraded} } sort keys %{$sockets};
    my @checks = (
        _check(
            'worker_count',
            $hypnotoad->{workers} < $runtime->web_processes,
            'configured web process count was capped to CPU policy'
        ),
        _check(
            'backlog',
            $hypnotoad->{backlog} < $MIN_BACKLOG,
            'configured listen backlog is below conservative deployment floor'
        ),
        _check(
            'features',
            scalar @degraded_features,
            'one or more requested socket features are unsupported'
        ),
        _check(
            'listen',
            !@{ $hypnotoad->{listen} },
            'no listen locations configured'
        ),
    );
    my $xsendfile =
      $runtime->os_profile->feature_snapshot( $runtime->os_feature_settings )
      ->{static_xsendfile}{enabled} ? 1 : 0;

    return {
        status => ( any { $_->{status} eq $STATUS_DEGRADED } @checks )
        ? $STATUS_DEGRADED
        : $STATUS_OK,
        checks    => \@checks,
        hypnotoad => $hypnotoad,
        effective => {
            configured_web_processes => $runtime->web_processes,
            effective_web_processes  => $self->_effective_web_processes,
            worker_policy            => $self->config->runtime_worker_policy,
            cpu_count                => $runtime->os_profile->cpu_count,
            max_web_per_cpu          => $self->config->runtime_max_web_per_cpu,
        },
        degraded_features => \@degraded_features,
        socket_runtime    => {
            reuseport   => _socket_runtime_entry( $sockets, 'reuseport' ),
            keepalive   => _socket_runtime_entry( $sockets, 'keepalive' ),
            tcp_nodelay => {
                %{ _socket_runtime_entry( $sockets, 'tcp_nodelay' ) },
                enforcement => 'mojolicious-ioloop',
            },
        },
        backlog => {
            configured => $hypnotoad->{backlog},
            saturation => {
                available => 0,
                reason    => 'portable listen queue saturation is not exposed',
            },
        },
        static_transfer => {
            mode => $sockets->{sendfile}{enabled} || $xsendfile ? 'delegated'
            : 'perl-fallback',
            sendfile  => $sockets->{sendfile},
            xsendfile => $xsendfile,
            boundary  => 'reverse-proxy-or-web-server',
        },
    };
}

sub readiness_check ($self) {
    my $report = $self->report;
    return {
        name   => 'runtime_enforcement',
        status => $report->{status},
        report => $report,
    };
}

sub _effective_web_processes ($self) {
    return GPForum::Runtime->capped_web_processes(
        $self->runtime->web_processes,
        $self->runtime->os_profile->cpu_count,
        $self->config->runtime_max_web_per_cpu,
        $self->config->runtime_worker_policy,
    );
}

# A relative pid file lives in the runtime directory when systemd made one, so
# the unit's PIDFile= follows from its RuntimeDirectory= line; a second setting
# that had to agree with it was the one way to lose track of the manager.
# Elsewhere, and under an outdated unit, it stays relative to the working
# directory, as before.
sub _pid_file ($self) {
    my $file      = $self->config->runtime_pid_file;
    my $directory = $self->_runtime_directory;
    return $file if !defined $directory || $self->outdated_unit;
    return $file if File::Spec->file_name_is_absolute($file);

    return File::Spec->catfile( $directory, $file );
}

# The first runtime directory, or undef.
sub _runtime_directory ($self) {
    my ($directory) = split /:/msx, $self->runtime_directory // q{};
    return defined $directory && length $directory ? $directory : undef;
}

sub _socket_snapshot ($self) {
    return $self->runtime->os_profile->socket_snapshot(
        $self->runtime->os_feature_settings );
}

sub _socket_runtime_entry ( $sockets, $name ) {
    return {
        supported   => $sockets->{$name}{supported},
        enabled     => $sockets->{$name}{enabled},
        degraded    => $sockets->{$name}{degraded},
        setting     => $sockets->{$name}{setting},
        enforcement => 'hypnotoad-config',
    };
}

sub _check ( $name, $degraded, $reason ) {
    return { name => $name, status => $STATUS_OK } if !$degraded;

    return {
        name   => $name,
        status => $STATUS_DEGRADED,
        reason => $reason,
    };
}

1;
