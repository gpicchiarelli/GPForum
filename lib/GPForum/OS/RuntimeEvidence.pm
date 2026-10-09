# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::RuntimeEvidence;

use Carp qw(croak);
use Const::Fast;
use Cwd        qw(abs_path);
use File::Temp qw(tempdir);
use List::Util qw(any);
use Mojo::Base -base, -signatures;
use v5.40;
use Socket ();

use GPForum::Config;
use GPForum::Runtime;
use GPForum::Infrastructure::Storage;
use GPForum::OS::RuntimePolicy;
use GPForum::Schema;

our $VERSION = '0.001';

const my $STATUS_ACTIVE          => 'active';
const my $STATUS_CONFIGURABLE    => 'configurable';
const my $STATUS_MISMATCH        => 'mismatch';
const my $STATUS_UNAVAILABLE     => 'unavailable';
const my $STATUS_NOT_IMPLEMENTED => 'not-implemented';

# getsockopt answers a C int.
const my $SOCKET_INT_BYTES => 4;

# The columns of one `df -P` line, in order.
const my @DF_COLUMNS =>
  qw(filesystem blocks used available_blocks capacity mounted_on);
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

# Each one is built on first use when it was not given: from the
# environment, from the database the configuration names, or a fresh
# temporary directory.
has config         => undef;    # optional: from the environment
has runtime        => undef;    # optional: from the configuration
has runtime_policy => undef;    # optional: from config and runtime
has dbh            => undef;    # optional: connected on first use
has tempfile_dir   => undef;    # optional: a fresh temporary directory

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
        status         => $self->_overall_status($runtime_report),
        os             => $os->snapshot,
        event_loop     => $self->_event_loop_report($os),
        hypnotoad      => $self->_hypnotoad_report($runtime_report),
        socket_options => {
            reuseaddr =>
              _probe_socket_option( 'reuseaddr', 'SOL_SOCKET', 'SO_REUSEADDR' ),
            reuseport =>
              _probe_socket_option( 'reuseport', 'SOL_SOCKET', 'SO_REUSEPORT' ),
            keepalive =>
              _probe_socket_option( 'keepalive', 'SOL_SOCKET', 'SO_KEEPALIVE' ),
            tcp_nodelay => _probe_socket_option(
                'tcp_nodelay', 'IPPROTO_TCP', 'TCP_NODELAY'
            ),
        },
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
    my $status   = $actual eq $expected ? $STATUS_ACTIVE : $STATUS_MISMATCH;

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
        reuseport_configured =>
          ( any { /(?: [?&] reuse=1 )/msx } @{ $hypnotoad->{listen} || [] } )
        ? 1
        : 0,
        backlog            => $hypnotoad->{backlog},
        clients            => $hypnotoad->{clients},
        accepts            => $hypnotoad->{requests},
        keep_alive_timeout => $hypnotoad->{keep_alive_timeout},
        graceful_timeout   => $hypnotoad->{graceful_timeout},
        proxy              => $hypnotoad->{proxy} ? 1 : 0,
        pid_file           => $hypnotoad->{pid_file},
    };
}

# The controller emits X-Accel-Redirect only when a prefix is configured, so
# x_accel_redirect_implemented reports what the running process would
# actually do rather than a constant. It read 0 for as long as nothing
# emitted the header at all.
sub _static_transfer_report ( $self, $runtime_report ) {
    my $transfer = $runtime_report->{static_transfer} || {};
    my $config   = $self->config;
    my $prefix;
    ## no critic (BuiltinFunctions::ProhibitUniversalCan)
    # Deliberate, as in Attachment::Delivery: a config double is free to
    # define its own can(), and this must ask about the method.
    if ( $config && UNIVERSAL::can( $config, 'attachment_accel_redirect' ) ) {
        $prefix = $config->attachment_accel_redirect;
    }
    ## use critic

    return {
        %{$transfer},
        status => $transfer->{mode} && $transfer->{mode} eq 'delegated'
        ? $STATUS_CONFIGURABLE
        : $STATUS_UNAVAILABLE,
        xsendfile_header_implemented => 0,
        x_accel_redirect_implemented => defined $prefix
          && length $prefix ? 1 : 0,
        materialized_in_benchmark => 0,
    };
}

sub _postgresql_report ($self) {
    my $dbh = $self->_dbh;
    return {
        status    => $STATUS_UNAVAILABLE,
        available => 0,
        reason    => 'database connection unavailable',
      }
      if !$dbh;

    my $rows;
    try {
        my $placeholders = join q{,}, map { q{?} } @POSTGRESQL_SETTINGS;
        $rows = $dbh->selectall_arrayref(
            <<"SQL", { Slice => {} }, @POSTGRESQL_SETTINGS );
SELECT name, setting, unit, source
  FROM pg_settings
 WHERE name IN ($placeholders)
 ORDER BY name
SQL
    }
    catch ($error) {
        $rows = undef;
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
    return $self->dbh if $self->dbh;

    my $schema;
    try {
        $schema = GPForum::Schema->connect_from_config( $self->_config );
    }
    catch ($error) {
        $schema = undef;
    };

    my $dbh = GPForum::Infrastructure::Storage->dbh_of($schema);
    return undef if !$dbh;

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
    my $class;
    try {
        require Mojo::IOLoop;
        $class = ref Mojo::IOLoop->singleton->reactor;
    }
    catch ($error) {
        $class = undef;
    };

    return $class || 'unknown';
}

sub _expected_reactor_class ($backend) {
    return 'Mojo::Reactor::EV' if $backend eq 'kqueue';
    return 'Mojo::Reactor::EV' if $backend eq 'epoll';

    return 'Mojo::Reactor::Poll';
}

sub _module_available ($module) {
    my $path = _module_path($module);
    return 0 if !_module_file_available($module);

    my $loaded = 0;
    try {
        require $path;
        $loaded = 1;
    }
    catch ($error) {
        $loaded = 0;
    };

    return $loaded;
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
      if $actual eq _expected_reactor_class($declared);
    return 'install optional EV module to activate Mojo::Reactor::EV'
      if $declared eq 'kqueue' || $declared eq 'epoll';

    return 'poll fallback acceptable for conservative unknown OS mode';
}

sub _probe_socket_option ( $name, $level_name, $option_name ) {
    my ( $level, $option, $family, $type, $protocol ) =
      map { _socket_constant($_) } $level_name, $option_name, 'AF_INET',
      'SOCK_STREAM', 'IPPROTO_TCP';

    if ( any { !defined } $level, $option, $family, $type, $protocol ) {
        return {
            status    => $STATUS_UNAVAILABLE,
            name      => $name,
            supported => 0,
            set       => 0,
            verified  => 0,
        };
    }

    socket my $socket, $family, $type,
      $protocol
      or return {
        status    => $STATUS_UNAVAILABLE,
        name      => $name,
        supported => 1,
        set       => 0,
        verified  => 0,
        reason    => 'socket creation failed',
      };
    my $set_ok = setsockopt $socket, $level, $option, pack 'i', 1;
    my $raw    = getsockopt $socket, $level, $option;
    my $value =
      defined $raw && length $raw >= $SOCKET_INT_BYTES
      ? unpack 'i', $raw
      : undef;
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

# The value of a Socket constant, or undef when this Socket does not name it:
# an optional capability, asked about rather than assumed.
sub _socket_constant ($name) {
    my $code = Socket->can($name);
    return undef if !$code;

    return $code->();
}

sub _df_report ($path) {
    open my $df, q{-|}, 'df', '-P', $path
      or return { path => $path, available => 0 };
    my @lines = <$df>;
    close $df or return { path => $path, available => 0 };

    my @fields = split /\s+/msx, trim( $lines[-1] || q{} );

    return { path => $path, available => 0 } if @fields < @DF_COLUMNS;

    my %report = ( path => $path, available => 1 );
    @report{@DF_COLUMNS} = @fields;

    return \%report;
}

sub _mount_report ($mounted_on) {
    return { available => 0 } if !$mounted_on;

    open my $mounts, q{-|}, 'mount' or return { available => 0 };
    while ( my $line = <$mounts> ) {
        if ( $line =~ /\s on \s \Q$mounted_on\E \s [(] ([^)]+) [)]/msx ) {
            my @options = split /,\s*/msx, $1;
            close $mounts or return { available => 0 };
            return {
                available => 1,
                raw       => trim($line),
                type      => $options[0] || 'unknown',
                options   => \@options,
            };
        }
    }
    close $mounts or return { available => 0 };

    return { available => 0 };
}

1;
