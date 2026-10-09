# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::Settings;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Config;
use GPForum::Config::Report;

our $VERSION = '0.001';

const my $REDACTED => '[redacted]';

# The old names of each renamed setting, by its new one: an environment that
# still sets an old one gave the value the page shows.
const my %OLD_NAMES => map { $_->[0] => $_->[1] }
  grep { @{ $_->[1] } }
  map {
    [
        $_->{env},
        [ map { exists $_->{env} ? $_->{env} : () } @{ $_->{aliases} } ]
    ]
  } @{ GPForum::Config->settings };

# Where an operator changes what this page shows. Configuration lives in the
# service's environment by design (GPForum::Config); the console reads it and
# never writes it. Both services read the file only when they start: the web
# service, and the outbox worker that sends the mail with the mail settings
# this page lists. Restarting the first alone left the worker sending with
# the old ones.
const my %CHANGE => (
    file            => '/etc/gpforum/gpforum.env',
    freebsd_file    => '/usr/local/etc/gpforum/gpforum.env',
    restart         => 'systemctl restart gpforum gpforum-outbox',
    freebsd_restart =>
      'service gpforum restart && service gpforum_outbox restart',
);

# Every variable GPForum::Config reads, with the Config attribute holding its
# effective value, grouped as an operator looks for them. t/212 fails when
# Config reads a GPFORUM_ variable missing here, so a new setting cannot be
# left off the page. A renamed setting is listed under its new name only,
# with the value the old one gave it (audit 5.6).
const my @SECTIONS => (
    {
        name     => 'application',
        settings => [
            [ GPFORUM_ENV              => 'environment' ],
            [ GPFORUM_PUBLIC_BASE_URL  => 'public_base_url' ],
            [ GPFORUM_DEFAULT_LOCALE   => 'default_locale' ],
            [ GPFORUM_DEFAULT_THEME    => 'default_theme' ],
            [ GPFORUM_DEFAULT_TIMEZONE => 'default_timezone' ],
            [ GPFORUM_LOG_LEVEL        => 'log_level' ],
            [ GPFORUM_LOG_PATH         => 'log_path' ],
            [ GPFORUM_ATTACHMENT_ROOT  => 'attachment_root' ],
            [
                GPFORUM_ATTACHMENT_ACCEL_REDIRECT => 'attachment_accel_redirect'
            ],
        ],
    },
    {
        name     => 'security',
        settings => [
            [ GPFORUM_SESSION_SECRET  => 'session_secret' ],
            [ GPFORUM_SESSION_SECRETS => 'previous_session_secrets' ],
            [
                GPFORUM_SESSION_TOUCH_INTERVAL_SECONDS =>
                  'session_touch_interval_seconds'
            ],
            [ GPFORUM_METRICS_TOKEN         => 'metrics_token' ],
            [ GPFORUM_METRICS_TOKENS        => 'previous_metrics_tokens' ],
            [ GPFORUM_FORUM_READ_RATE_LIMIT => 'forum_read_rate_limit' ],
        ],
    },
    {
        name     => 'database',
        settings => [
            [ GPFORUM_DATABASE_DSN      => 'database_dsn' ],
            [ GPFORUM_DATABASE_USER     => 'database_user' ],
            [ GPFORUM_DATABASE_PASSWORD => 'database_password' ],
            [
                GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS =>
                  'database_statement_timeout_ms'
            ],
            [
                GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS =>
                  'database_idle_in_transaction_timeout_ms'
            ],
            [ GPFORUM_DATABASE_LOCK_TIMEOUT_MS => 'database_lock_timeout_ms' ],
        ],
    },
    {
        name     => 'search',
        settings => [
            [
                GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS =>
                  'search_statement_timeout_ms'
            ],
            [ GPFORUM_SEARCH_CANDIDATE_LIMIT => 'search_candidate_limit' ],
        ],
    },
    {
        name     => 'mail',
        settings => [
            [ GPFORUM_MAIL_TRANSPORT => 'mail_transport' ],
            [ GPFORUM_MAIL_FROM      => 'mail_from' ],
            [ GPFORUM_SMTP_HOST      => 'smtp_host' ],
            [ GPFORUM_SMTP_PORT      => 'smtp_port' ],
            [ GPFORUM_SMTP_TLS       => 'smtp_tls' ],
            [ GPFORUM_SMTP_USERNAME  => 'smtp_username' ],
            [ GPFORUM_SMTP_PASSWORD  => 'smtp_password' ],
        ],
    },
    {
        name     => 'antivirus',
        settings => [
            [ GPFORUM_ANTIVIRUS         => 'antivirus' ],
            [ GPFORUM_ANTIVIRUS_SOCKET  => 'antivirus_socket' ],
            [ GPFORUM_ANTIVIRUS_COMMAND => 'antivirus_command' ],
            [
                GPFORUM_ANTIVIRUS_TIMEOUT_SECONDS =>
                  'antivirus_timeout_seconds'
            ],
        ],
    },
    {
        name     => 'processes',
        settings => [
            [ GPFORUM_WARMUP_ENABLED             => 'warmup_enabled' ],
            [ GPFORUM_WEB_PROCESSES              => 'web_processes' ],
            [ GPFORUM_WORKER_PROCESSES           => 'worker_processes' ],
            [ GPFORUM_REALTIME_PROCESSES         => 'realtime_processes' ],
            [ GPFORUM_RUNTIME_LISTEN             => 'runtime_listen' ],
            [ GPFORUM_RUNTIME_WORKER_POLICY      => 'runtime_worker_policy' ],
            [ GPFORUM_RUNTIME_MAX_WEB_PER_CPU    => 'runtime_max_web_per_cpu' ],
            [ GPFORUM_RUNTIME_BACKLOG            => 'runtime_backlog' ],
            [ GPFORUM_RUNTIME_CLIENTS            => 'runtime_clients' ],
            [ GPFORUM_RUNTIME_REQUESTS           => 'runtime_requests' ],
            [ GPFORUM_RUNTIME_KEEP_ALIVE_TIMEOUT => 'runtime_keep_alive' ],
            [ GPFORUM_RUNTIME_INACTIVITY_TIMEOUT => 'runtime_inactivity' ],
            [ GPFORUM_RUNTIME_GRACEFUL_TIMEOUT => 'runtime_graceful_timeout' ],
            [
                GPFORUM_RUNTIME_HEARTBEAT_INTERVAL =>
                  'runtime_heartbeat_interval'
            ],
            [
                GPFORUM_RUNTIME_HEARTBEAT_TIMEOUT => 'runtime_heartbeat_timeout'
            ],
            [ GPFORUM_RUNTIME_UPGRADE_TIMEOUT => 'runtime_upgrade_timeout' ],
            [ GPFORUM_RUNTIME_SPARE_PROCESSES => 'runtime_spare_processes' ],
            [ GPFORUM_RUNTIME_PROXY           => 'runtime_proxy' ],
            [ GPFORUM_RUNTIME_TRUSTED_PROXIES => 'runtime_trusted_proxies' ],
            [ GPFORUM_RUNTIME_PID_FILE        => 'runtime_pid_file' ],
        ],
    },
    {
        name     => 'operating_system',
        settings => [
            [ GPFORUM_OS_REUSEPORT        => 'os_reuseport' ],
            [ GPFORUM_OS_SENDFILE         => 'os_sendfile' ],
            [ GPFORUM_OS_WORKER_PRIORITY  => 'os_worker_priority' ],
            [ GPFORUM_OS_STATIC_XSENDFILE => 'os_static_xsendfile' ],
            [ GPFORUM_OS_AFFINITY         => 'os_affinity' ],
            [
                GPFORUM_OS_MIN_RECOMMENDED_WORKERS =>
                  'os_min_recommended_workers'
            ],
            [
                GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS =>
                  'os_max_open_file_descriptors'
            ],
        ],
    },
    {
        name     => 'cache',
        settings => [
            [ GPFORUM_LOCAL_CACHE_MAX_ENTRIES => 'local_cache_max_entries' ],
            [
                GPFORUM_CATEGORY_CACHE_TTL_SECONDS =>
                  'category_cache_ttl_seconds'
            ],
            [ GPFORUM_GLIFISTORE_URL => 'glifistore_url' ],
        ],
    },
    {
        name     => 'realtime',
        settings => [
            [
                GPFORUM_REALTIME_LISTENER_ENABLED =>
                  'realtime_listener_enabled'
            ],
            [
                GPFORUM_REALTIME_LISTENER_POLL_INTERVAL_SECONDS =>
                  'realtime_listener_poll_interval_seconds'
            ],
            [
                GPFORUM_REALTIME_LISTENER_RECONNECT_BACKOFF_SECONDS =>
                  'realtime_listener_reconnect_backoff_seconds'
            ],
            [
                GPFORUM_REALTIME_LISTENER_HEARTBEAT_INTERVAL_SECONDS =>
                  'realtime_listener_heartbeat_interval_seconds'
            ],
        ],
    },
    {
        name     => 'jobs',
        settings => [
            [ GPFORUM_MINION_ENABLED       => 'minion_enabled' ],
            [ GPFORUM_MINION_PG_URL        => 'minion_pg_url' ],
            [ GPFORUM_EVENT_RETENTION_DAYS => 'event_retention_days' ],
        ],
    },
);

# Shown only as set or not: whatever signs a session, authenticates a scrape
# or logs in somewhere. A name that reads like a secret counts as one even if
# this list forgets it, so a new GPFORUM_*_TOKEN is hidden from its first day.
const my %SECRET => map { $_ => 1 } qw(
  GPFORUM_DATABASE_PASSWORD
  GPFORUM_METRICS_TOKEN
  GPFORUM_METRICS_TOKENS
  GPFORUM_SESSION_SECRET
  GPFORUM_SESSION_SECRETS
  GPFORUM_SMTP_PASSWORD
  GPFORUM_SMTP_USERNAME
);
const my $SECRET_WORD => qr/SECRET|PASSW(?:OR)?D|TOKEN|CREDENTIAL/msx;
const my $SECRET_ROLE => qr/PRIVATE|USERNAME|_KEY\z/msx;

has config      => undef;                   # optional: redact reads none
has environment => sub { return \%ENV; };

# The effective configuration, section by section: each setting's variable,
# its value (or, for a secret, only whether it is set) and whether the value
# came from the environment or is the built-in default.
sub view ($self) {
    my $secrets = $self->secret_values;

    return {
        change   => {%CHANGE},
        sections => [ map { $self->_section( $_, $secrets ) } @SECTIONS ],
    };
}

# Every variable the page lists, in its order.
sub env_names ($class) {
    return [ map { $_->[0] } map { @{ $_->{settings} } } @SECTIONS ];
}

sub is_secret ( $class, $env_name ) {
    return ( exists $SECRET{$env_name}
          || $env_name =~ $SECRET_WORD
          || $env_name =~ $SECRET_ROLE ) ? 1 : 0;
}

# The configured value of every secret setting, longest first, so text that
# quotes one -- a mail transport's error, say -- can be scrubbed of it.
sub secret_values ($self) {
    my %values;
    for my $setting ( map { @{ $_->{settings} } } @SECTIONS ) {
        my ( $env_name, $attribute ) = @{$setting};
        next if !$self->is_secret($env_name);

        my $value = $self->config->$attribute;
        for my $secret ( ref $value eq 'ARRAY' ? @{$value} : $value ) {
            if ( defined $secret && length $secret ) {
                $values{$secret} = 1;
            }
        }
    }

    my @shortest_first =
      sort { length $a <=> length $b || $a cmp $b } keys %values;

    return [ reverse @shortest_first ];
}

# Text with every configured secret, and every inline password, replaced.
# The secrets go in one pass, longest first, so a short secret cannot match
# inside the marker that replaced a longer one.
sub redact ( $self, $text, $secrets = undef ) {
    return $text if !defined $text;

    $secrets //= $self->secret_values;
    if ( @{$secrets} ) {
        my $any = join q{|}, map { quotemeta } @{$secrets};
        $text =~ s/(?:$any)/$REDACTED/gmsx;
    }

    # A setting that is not a secret can still carry one, a DSN's password=
    # or a URL's user:password@: GPForum::Config::Report replaces them, as it
    # does in the report of a setting it refuses.
    return GPForum::Config::Report->without_passwords($text);
}

sub _section ( $self, $section, $secrets ) {
    return {
        name     => $section->{name},
        settings => [
            map { $self->_setting( @{$_}, $secrets ) } @{ $section->{settings} }
        ],
    };
}

sub _setting ( $self, $env_name, $attribute, $secrets ) {
    my $value   = $self->config->$attribute;
    my %setting = (
        env    => $env_name,
        name   => $attribute,
        source => $self->_source($env_name),
    );

    # The value never leaves this method for a secret: not redacted, not
    # hashed, not its length. Whether it is set is what an operator needs.
    if ( $self->is_secret($env_name) ) {
        my @values =
          grep { defined && length } ref $value eq 'ARRAY'
          ? @{$value}
          : ($value);
        return {
            %setting,
            configured => scalar @values,
            list       => ref $value eq 'ARRAY' ? 1 : 0,
            secret     => 1,
        };
    }

    return {
        %setting,
        secret => 0,
        value  => $self->redact( _text($value), $secrets ),
    };
}

# Config takes a variable when it is present and not empty, as here, and a
# renamed setting's old name when the new one is not.
sub _source ( $self, $env_name ) {
    my @names = (
        $env_name,
        exists $OLD_NAMES{$env_name} ? @{ $OLD_NAMES{$env_name} } : ()
    );
    for my $name (@names) {
        my $raw = $self->environment->{$name};
        return 'environment' if defined $raw && length $raw;
    }

    return 'default';
}

sub _text ($value) {
    return q{} if !defined $value;
    return join q{ }, @{$value} if ref $value eq 'ARRAY';

    return "$value";
}

1;

__END__

=head1 NAME

GPForum::Service::Admin::Settings - The effective configuration, with secrets redacted, for the console.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $settings = GPForum::Service::Admin::Settings->new( config => $config );
    my $view     = $settings->view;
    my $safe     = $settings->redact($transport_error);

=head1 DESCRIPTION

What C</admin/settings> shows (quality program 6.5): every variable
L<GPForum::Config> reads, its effective value, and whether that value came
from the environment or is the built-in default. Secrets -- the session
secrets, the database password, the metrics tokens and the SMTP credentials,
and any variable whose name reads like a secret -- are shown only as set or
not set. A value that is not a secret but embeds one, such as a DSN's
C<password=> or a URL's C<user:password@>, has that part replaced, and so has
any configured secret that appears inside another value.

Configuration lives in the service's environment
(F</etc/gpforum/gpforum.env>); this module reads it and writes nothing.

=head1 SUBROUTINES/METHODS

=head2 view

The sections, each with its settings (C<env>, C<name>, C<source>, C<secret>,
and C<value> or, for a secret, C<configured> and C<list>), and where to
change them: C<change> holds the environment file (C<file>, and
C<freebsd_file>) and the command that restarts both services that read it,
the web service and the outbox worker (C<restart>, and C<freebsd_restart>).

=head2 env_names

Every variable listed, in page order.

=head2 is_secret

True for a variable shown only as set or not set.

=head2 secret_values

The configured secret values, longest first.

=head2 redact

The text with every configured secret and every inline password replaced by
C<[redacted]>.

=head1 DIAGNOSTICS

None; it reads an already validated configuration.

=head1 CONFIGURATION AND ENVIRONMENT

Reads the process environment only to tell an environment value from a
default.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<GPForum::Config>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

It shows what this web process loaded at start. A change to the environment
file takes effect, and shows here, after a restart.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
