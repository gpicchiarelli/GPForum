package GPForum::OS::RuntimeEvidence;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Cwd        qw(abs_path);
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::Base -base;
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

sub from_environment {
    my ($class) = @_;

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

sub report {
    my ($self) = @_;

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

sub _runtime {
    my ($self) = @_;

    return $self->runtime if $self->runtime;

    my $config = $self->_config;
    $self->runtime( GPForum::Runtime->from_config($config) );

    return $self->runtime;
}

sub _config {
    my ($self) = @_;

    return $self->config if $self->config;

    $self->config( GPForum::Config->from_environment );

    return $self->config;
}

sub _runtime_policy {
    my ($self) = @_;

    return $self->runtime_policy if $self->runtime_policy;

    $self->runtime_policy(
        GPForum::OS::RuntimePolicy->new(
            config  => $self->_config,
            runtime => $self->_runtime,
        )
    );

    return $self->runtime_policy;
}

sub _overall_status {
    my ( $self, $runtime_report ) = @_;

    return $STATUS_MISMATCH
      if $self->_event_loop_report( $self->_runtime->os_profile )->{status} eq
      $STATUS_MISMATCH;
    return $STATUS_MISMATCH
      if $runtime_report->{status} && $runtime_report->{status} ne 'ok';

    return $STATUS_ACTIVE;
}

sub _event_loop_report {
    my ( $self, $os ) = @_;

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
        modules              => {
            kqueue => _module_available('Mojo::Reactor::KQueue'),
            ev     => _module_available('Mojo::Reactor::EV'),
        },
    };
}

sub _hypnotoad_report {
    my ( $self, $runtime_report ) = @_;

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

sub _socket_option_report {
    my ($self) = @_;

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

sub _static_transfer_report {
    my ( $self, $runtime_report ) = @_;

    my $transfer = $runtime_report->{static_transfer} || {};

    return {
        %{$transfer},
        status => $transfer->{mode} && $transfer->{mode} eq 'delegated'
        ? $STATUS_CONFIGURABLE
        : $STATUS_UNAVAILABLE,
        xsendfile_header_implemented => 0,
        x_accel_redirect_implemented => 0,
        materialized_in_benchmark    => 0,
    };
}

sub _postgresql_report {
    my ($self) = @_;

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

sub _filesystem_report {
    my ($self) = @_;

    my $path = $self->_temp_path;
    my $df   = _df_report($path);

    return {
        status    => $df->{mounted_on} ? $STATUS_ACTIVE : $STATUS_UNAVAILABLE,
        temp_path => $path,
        df        => $df,
        mount     => _mount_report( $df->{mounted_on} ),
    };
}

sub _dbh {
    my ($self) = @_;

    return $self->dbh if $self->dbh;

    my $schema =
      eval { return GPForum::Schema->connect_from_config( $self->_config ); };
    return if !$schema;

    my $dbh = eval { return $schema->storage->dbh; };
    return if !$dbh;

    $self->dbh($dbh);

    return $dbh;
}

sub _temp_path {
    my ($self) = @_;

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

sub _expected_reactor_class {
    my ($backend) = @_;

    return 'Mojo::Reactor::KQueue' if $backend eq 'kqueue';
    return 'Mojo::Reactor::EV'     if $backend eq 'epoll';

    return 'Mojo::Reactor::Poll';
}

sub _reactor_matches {
    my ( $actual, $expected ) = @_;

    return 1 if $actual eq $expected;
    return 1 if $expected eq 'Mojo::Reactor::EV' && $actual eq $expected;

    return 0;
}

sub _module_available {
    my ($module) = @_;

    my $path = $module;
    $path =~ s{::}{/}gmsx;
    $path .= '.pm';

    return eval {
        require $path;
        return 1;
    } ? 1 : 0;
}

sub _probe_socket_option {
    my ( $name, $level_name, $option_name ) = @_;

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

sub _unsupported_socket_option {
    my ($name) = @_;

    return {
        status    => $STATUS_UNAVAILABLE,
        name      => $name,
        supported => 0,
        set       => 0,
        verified  => 0,
    };
}

sub _failed_socket_option {
    my ( $name, $reason ) = @_;

    return {
        status    => $STATUS_UNAVAILABLE,
        name      => $name,
        supported => 1,
        set       => 0,
        verified  => 0,
        reason    => $reason,
    };
}

sub _socket_constant {
    my ($name) = @_;

    my $code = Socket->can($name);
    return if !$code;

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

sub _df_report {
    my ($path) = @_;

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

sub _mount_report {
    my ($mounted_on) = @_;

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

sub _mount_type {
    my ($options) = @_;

    my ($type) = split /,\s*/msx, $options;
    return $type || 'unknown';
}

sub _listen_has_reuseport {
    my ($listen) = @_;

    for my $location ( @{ $listen || [] } ) {
        return 1 if $location =~ /(?: [?&] reuse=1 )/msx;
    }

    return 0;
}

sub _trim {
    my ($value) = @_;

    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

1;
