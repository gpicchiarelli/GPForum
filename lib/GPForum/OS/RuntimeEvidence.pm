# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::RuntimeEvidence;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Cwd        qw(abs_path);
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::Base -base, -signatures;
use Socket ();

use GPForum::Config;
use GPForum::Runtime;
use GPForum::OS::RuntimePolicy;
use GPForum::Schema;

our $VERSION = '0.001';

const my $STATUS_ACTIVE          => 'active';
const my $STATUS_CONFIGURABLE    => 'configurable';
const my $STATUS_MISMATCH        => 'mismatch';
const my $STATUS_UNAVAILABLE     => 'unavailable';
const my $STATUS_NOT_IMPLEMENTED => 'not-implemented';
const my @POSTGRESQL_SETTINGS => qw(
  checkpoint_completion_target
  checkpoint_timeout
  effective_cache_size
  effective_io_concurrency
  maintenance_work_mem
  max_connections
  max_wal_size
  min_wal_size
  random_page_cost
  shared_buffers
  synchronous_commit
  wal_buffers
  work_mem
);

has config         => undef;
has runtime        => undef;
has runtime_policy => undef;
has dbh            => undef;
has tempfile_dir   => undef;

sub from_environment ($class) {
    my $config  = GPForum::Config->from_environment;
    my $runtime = GPForum::Runtime->from_config($config);

    return $class->new(
        config         => $config,
        runtime        => $runtime,
        runtime_policy => GPForum::OS::RuntimePolicy->new(
            config  => $config,
            runtime => $runtime,
        ),
    );
}

sub report ($self) {
    my $runtime_policy = $self->_runtime_policy;
    my $runtime_report = $runtime_policy->report;
    my $os             = $self->_runtime->os_profile;

    return {
        status          => $self->_overall_status($runtime_report),
        os              => $os->snapshot,
        event_loop      => $self->_event_loop_report($os),
        hypnotoad       => $self->_hypnotoad_report($runtime_report),
        socket_options  => $self->_socket_option_report,
        static_transfer => $self->_static_transfer_report($runtime_report),
        postgresql      => $self->_postgresql_report,
        filesystem      => $self->_filesystem_report,
    };
}

sub _runtime ($self) {
    return $self->runtime if $self->runtime;

    my $config = $self->_config;
    $self->runtime( GPForum::Runtime->from_config($config) );

    return $self->runtime;
}

sub _config ($self) {
    return $self->config if $self->config;

    $self->config( GPForum::Config->from_environment );

    return $self->config;
}

sub _runtime_policy ($self) {
    return $self->runtime_policy if $self->runtime_policy;

    $self->runtime_policy(
        GPForum::OS::RuntimePolicy->new(
            config  => $self->_config,
            runtime => $self->_runtime,
        )
    );

    return $self->runtime_policy;
}

sub _overall_status ( $self, $runtime_report ) {
    return $STATUS_MISMATCH
      if $self->_event_loop_report( $self->_runtime->os_profile )->{status} eq
      $STATUS_MISMATCH;
    return $STATUS_MISMATCH
      if $runtime_report->{status} && $runtime_report->{status} ne 'ok';

    return $STATUS_ACTIVE;
}

sub _event_loop_report ( $self, $os ) {
    my $declared = $os->event_backend;
    my $actual   = _actual_reactor();
    my $expected = _expected_reactor_class($declared);
    my $status =
      _reactor_matches( $actual, $expected )
      ? $STATUS_ACTIVE
      : $STATUS_MISMATCH;

    return {
        status               => $status,
        declared_backend     => $declared,
        actual_reactor_class => $actual,
        expected_reactor     => $expected,
        portable_fallback    => $actual =~ /Poll\z/msx ? 1 : 0,
        recommendation       => _reactor_recommendation( $declared, $actual ),
        modules              => {
            mojo_ev   => _module_file_available('Mojo::Reactor::EV'),
            ev        => _module_available('EV'),
            io_kqueue => _module_available('IO::KQueue'),
        },
    };
}

sub _hypnotoad_report ( $self, $runtime_report ) {
    my $hypnotoad = $runtime_report->{hypnotoad} || {};
    my $workers   = $hypnotoad->{workers}        || 0;

    return {
        status  => $workers > 1 ? $STATUS_ACTIVE : $STATUS_CONFIGURABLE,
        prefork => $workers > 1 ? 1              : 0,
        workers              => $workers,
        listen               => $hypnotoad->{listen} || [],
        reuseport_configured => _listen_has_reuseport( $hypnotoad->{listen} ),
        backlog              => $hypnotoad->{backlog},
        clients              => $hypnotoad->{clients},
        accepts              => $hypnotoad->{requests},
        keep_alive_timeout   => $hypnotoad->{keep_alive_timeout},
        graceful_timeout     => $hypnotoad->{graceful_timeout},
        proxy                => $hypnotoad->{proxy} ? 1 : 0,
        pid_file             => $hypnotoad->{pid_file},
    };
}

sub _socket_option_report ($self) {
    return {
        reuseaddr =>
          _probe_socket_option( 'reuseaddr', 'SOL_SOCKET', 'SO_REUSEADDR' ),
        reuseport =>
          _probe_socket_option( 'reuseport', 'SOL_SOCKET', 'SO_REUSEPORT' ),
        keepalive =>
          _probe_socket_option( 'keepalive', 'SOL_SOCKET', 'SO_KEEPALIVE' ),
        tcp_nodelay =>
          _probe_socket_option( 'tcp_nodelay', 'IPPROTO_TCP', 'TCP_NODELAY' ),
    };
}

sub _static_transfer_report ( $self, $runtime_report ) {
    my $transfer = $runtime_report->{static_transfer} || {};

    return {
        %{$transfer},
        status => $transfer->{mode} && $transfer->{mode} eq 'delegated'
        ? $STATUS_CONFIGURABLE
        : $STATUS_UNAVAILABLE,
        xsendfile_header_implemented => 0,
        x_accel_redirect_implemented => $self->_accel_redirect_configured,
        materialized_in_benchmark    => 0,
    };
}

# The controller emits X-Accel-Redirect only when a prefix is configured, so
# this reports what the running process would actually do rather than a
# constant. It read 0 for as long as nothing emitted the header at all.
sub _accel_redirect_configured ($self) {
    my $config = $self->config;
    return 0 if !$config;
    ## no critic (BuiltinFunctions::ProhibitUniversalCan)
    # Deliberate, as in Attachment::Delivery: a config double is free to
    # define its own can(), and this must ask about the method.
    return 0 if !UNIVERSAL::can( $config, 'attachment_accel_redirect' );
    ## use critic

    my $prefix = $config->attachment_accel_redirect;

    return defined $prefix && length $prefix ? 1 : 0;
}

sub _postgresql_report ($self) {
    my $dbh = $self->_dbh;
    return {
        status    => $STATUS_UNAVAILABLE,
        available => 0,
        reason    => 'database connection unavailable',
      }
      if !$dbh;

    my $rows = eval {
        return $dbh->selectall_arrayref(
            _postgresql_settings_sql(),
            { Slice => {} },
            @POSTGRESQL_SETTINGS,
        );
    };
    return {
        status    => $STATUS_UNAVAILABLE,
        available => 0,
        reason    => 'pg_settings query failed',
      }
      if !$rows;

    my %settings;
    for my $row ( @{$rows} ) {
        $settings{ $row->{name} } = {
            setting => $row->{setting},
            unit    => $row->{unit},
            source  => $row->{source},
        };
    }

    return {
        status             => $STATUS_CONFIGURABLE,
        available          => 1,
        settings           => \%settings,
        tuning_scope       => 'server-current-settings',
        applied_by_gpforum => 0,
    };
}

sub _filesystem_report ($self) {
    my $path = $self->_temp_path;
    my $df   = _df_report($path);

    return {
        status    => $df->{mounted_on} ? $STATUS_ACTIVE : $STATUS_UNAVAILABLE,
        temp_path => $path,
        df        => $df,
        mount     => _mount_report( $df->{mounted_on} ),
    };
}

sub _dbh ($self) {
    my $undefined;
    return $self->dbh if $self->dbh;

    my $schema =
      eval { return GPForum::Schema->connect_from_config( $self->_config ); };
    return $undefined if !$schema;

    my $dbh = eval { return $schema->storage->dbh; };
    return $undefined if !$dbh;

    $self->dbh($dbh);

    return $dbh;
}

sub _temp_path ($self) {
    return $self->tempfile_dir if $self->tempfile_dir;

    my $directory =
      tempdir( 'gpforum-os-evidence-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $path = abs_path($directory) || $directory;
    $self->tempfile_dir($path);

    return $path;
}

sub _actual_reactor {
    my $class = eval {
        require Mojo::IOLoop;
        return ref Mojo::IOLoop->singleton->reactor;
    };

    return $class || 'unknown';
}

sub _expected_reactor_class ($backend) {
    return 'Mojo::Reactor::EV' if $backend eq 'kqueue';
    return 'Mojo::Reactor::EV' if $backend eq 'epoll';

    return 'Mojo::Reactor::Poll';
}

sub _reactor_matches ( $actual, $expected ) {
    return 1 if $actual eq $expected;
    return 1 if $expected eq 'Mojo::Reactor::EV' && $actual eq $expected;

    return 0;
}

sub _module_available ($module) {
    my $path = _module_path($module);
    return 0 if !_module_file_available($module);

    return eval {
        require $path;
        return 1;
    } ? 1 : 0;
}

sub _module_file_available ($module) {
    my $path = _module_path($module);

    for my $include (@INC) {
        return 1 if -e "$include/$path";
    }

    return 0;
}

sub _module_path ($module) {
    my $path = $module;
    $path =~ s{::}{/}gmsx;
    $path .= '.pm';

    return $path;
}

sub _reactor_recommendation ( $declared, $actual ) {
    return 'native-reactor-active'
      if _reactor_matches( $actual, _expected_reactor_class($declared) );
    return 'install optional EV module to activate Mojo::Reactor::EV'
      if $declared eq 'kqueue' || $declared eq 'epoll';

    return 'poll fallback acceptable for conservative unknown OS mode';
}

sub _probe_socket_option ( $name, $level_name, $option_name ) {
    my $level    = _socket_constant($level_name);
    my $option   = _socket_constant($option_name);
    my $family   = _socket_constant('AF_INET');
    my $type     = _socket_constant('SOCK_STREAM');
    my $protocol = _socket_constant('IPPROTO_TCP');

    return _unsupported_socket_option($name)
      if !defined $level
      || !defined $option
      || !defined $family
      || !defined $type
      || !defined $protocol;

    socket my $socket, $family, $type, $protocol
      or return _failed_socket_option( $name, 'socket creation failed' );
    my $set_ok = setsockopt $socket, $level, $option, pack 'i', 1;
    my $raw    = getsockopt $socket, $level, $option;
    my $value  = defined $raw && length $raw >= 4 ? unpack 'i', $raw : undef;
    close $socket or croak 'failed to close socket evidence probe';

    return {
        status    => $set_ok ? $STATUS_ACTIVE : $STATUS_UNAVAILABLE,
        name      => $name,
        supported => 1,
        set       => $set_ok                  ? 1 : 0,
        verified  => defined $value && $value ? 1 : 0,
        level     => $level_name,
        option    => $option_name,
    };
}

sub _unsupported_socket_option ($name) {
    return {
        status    => $STATUS_UNAVAILABLE,
        name      => $name,
        supported => 0,
        set       => 0,
        verified  => 0,
    };
}

sub _failed_socket_option ( $name, $reason ) {
    return {
        status    => $STATUS_UNAVAILABLE,
        name      => $name,
        supported => 1,
        set       => 0,
        verified  => 0,
        reason    => $reason,
    };
}

sub _socket_constant ($name) {
    my $code = Socket->can($name);
    my $undefined;
    return $undefined if !$code;

    return $code->();
}

sub _postgresql_settings_sql {
    my $placeholders = join q{,}, map { q{?} } @POSTGRESQL_SETTINGS;

    return <<"SQL";
SELECT name, setting, unit, source
  FROM pg_settings
 WHERE name IN ($placeholders)
 ORDER BY name
SQL
}

sub _df_report ($path) {
    open my $df, q{-|}, 'df', '-P', $path
      or return { path => $path, available => 0 };
    my @lines = <$df>;
    close $df or return { path => $path, available => 0 };

    my $line = $lines[-1] || q{};
    $line =~ s/\A \s+//msx;
    $line =~ s/\s+ \z//msx;
    my @fields = split /\s+/msx, $line;

    return { path => $path, available => 0 } if @fields < 6;

    return {
        path             => $path,
        available        => 1,
        filesystem       => $fields[0],
        blocks           => $fields[1],
        used             => $fields[2],
        available_blocks => $fields[3],
        capacity         => $fields[4],
        mounted_on       => $fields[5],
    };
}

sub _mount_report ($mounted_on) {
    return { available => 0 } if !$mounted_on;

    open my $mounts, q{-|}, 'mount' or return { available => 0 };
    while ( my $line = <$mounts> ) {
        next if $line !~ /\s on \s \Q$mounted_on\E \s [(] ([^)]+) [)]/msx;
        close $mounts or return { available => 0 };
        return {
            available => 1,
            raw       => _trim($line),
            type      => _mount_type($1),
            options   => [ split /,\s*/msx, $1 ],
        };
    }
    close $mounts or return { available => 0 };

    return { available => 0 };
}

sub _mount_type ($options) {
    my ($type) = split /,\s*/msx, $options;
    return $type || 'unknown';
}

sub _listen_has_reuseport ($listen) {
    for my $location ( @{ $listen || [] } ) {
        return 1 if $location =~ /(?: [?&] reuse=1 )/msx;
    }

    return 0;
}

sub _trim ($value) {
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

1;
