# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::Preflight;

use Const::Fast;
use JSON::MaybeXS;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::OS;
use GPForum::Runtime;

our $VERSION = '0.001';

const my $UNKNOWN_OS                      => 'unknown';
const my $SELECT_BACKEND                  => 'select';
const my $MINIMUM_CPU_COUNT               => 1;
const my $MINIMUM_WORKER_COUNT            => 1;
const my $DEFAULT_MINIMUM_FD_LIMIT        => 65_536;
const my $DEFAULT_MAX_OPEN_FDS            => 65_536;
const my $DEFAULT_MAX_WEB_PER_CPU         => 2;
const my $DEFAULT_MIN_RECOMMENDED_WORKERS => 1;
const my $DEFAULT_WORKER_POLICY           => 'cap-to-cpu';
const my $FD_USAGE_DEGRADED_RATIO         => 0.8;
const my $STATUS_OK                       => 'ok';
const my $STATUS_DEGRADED                 => 'degraded';
const my $STATUS_FAIL                     => 'fail';
const my $FEATURE_ON                      => 'on';
const my @SUPPORT_GATED_FEATURES => qw(reuseport sendfile static_xsendfile);

has os                            => sub { return GPForum::OS->detect; };
has os_feature_settings           => sub { return {}; };
has profile                       => undef;    # optional: probed
has min_recommended_workers       => $DEFAULT_MIN_RECOMMENDED_WORKERS;
has max_open_file_descriptors     => $DEFAULT_MAX_OPEN_FDS;
has minimum_file_descriptor_limit => $DEFAULT_MINIMUM_FD_LIMIT;
has max_web_processes_per_cpu     => $DEFAULT_MAX_WEB_PER_CPU;
has worker_policy                 => $DEFAULT_WORKER_POLICY;

sub from_runtime ( $class, $runtime, %options ) {
    return $class->new(
        profile => $runtime ? $runtime->as_hash : undef,
        %options,
    );
}

sub report ($self) {
    my $profile = $self->_profile;
    my $context = {
        os => $profile->{os} || {},

        # Hypnotoad's web processes are the only ones a setting sizes: the
        # worker and realtime counts were retired and are not reported.
        runtime   => { web_processes => $profile->{web_processes} },
        features  => $profile->{os_features}  || {},
        sockets   => $profile->{os_sockets}   || {},
        processes => $profile->{os_processes} || {},

        # The runtime's own, when it carries them (GPForum::Runtime does), so
        # the check counts the web processes Hypnotoad is actually given.
        worker_policy   => $profile->{worker_policy} // $self->worker_policy,
        max_web_per_cpu => $profile->{max_web_per_cpu}
          // $self->max_web_processes_per_cpu,
    };
    my @checks = (
        _platform_checks($context),
        $self->_worker_checks($context),
        $self->_file_descriptor_checks($context),
        _swap_pressure_check($context),
        _feature_support_check($context),
        _socket_policy_check($context),
        _process_policy_check($context),
    );

    return {
        status          => _overall_status( \@checks ),
        os              => $context->{os},
        runtime         => $context->{runtime},
        resources       => $context->{os}{resources} || {},
        recommendations => $self->_recommendations,
        features        => $context->{features},
        sockets         => $context->{sockets},
        processes       => $context->{processes},
        checks          => \@checks,
    };
}

sub summary ($self) {
    my $report = $self->report;
    return {
        status => $report->{status},
        checks => $report->{checks},
    };
}

sub as_json ($self) {
    return JSON::MaybeXS->new( canonical => 1 )->encode( $self->report ) . "\n";
}

sub _profile ($self) {
    return $self->profile if $self->profile;

    return {
        os          => $self->os->snapshot,
        os_features =>
          $self->os->feature_snapshot( $self->os_feature_settings ),
        os_sockets => $self->os->socket_snapshot( $self->os_feature_settings ),
        os_processes =>
          $self->os->process_snapshot( $self->os_feature_settings ),
    };
}

# The OS profile itself: which OS, its event backend and its CPU count.
# Each check that is not ok carries the key of its sentence in the
# command-line catalogs (locale/cli/) and the values the sentence names, so
# what an operator reads is written in their language from the same facts
# the English reason states.
sub _platform_checks ($context) {
    my $os      = $context->{os};
    my $name    = $os->{name};
    my $backend = $os->{event_backend};

    my $os_check =
      !$name
      ? _failed_check( 'os', 'OS profile missing', ['preflight.os_missing'] )
      : $name eq $UNKNOWN_OS
      ? _degraded_check( 'os', 'unknown OS uses conservative mode',
        ['preflight.os_unknown'] )
      : _ok_check('os');
    my $backend_check =
      !$backend ? _failed_check(
        'event_backend',
        'event backend missing',
        ['preflight.backend_missing']
      )
      : $backend eq $SELECT_BACKEND ? _degraded_check(
        'event_backend',
        'select backend is conservative',
        ['preflight.backend_select']
      )
      : _ok_check('event_backend');
    my $cpu_check =
      ( $os->{cpu_count} || 0 ) < $MINIMUM_CPU_COUNT
      ? _failed_check( 'cpu_count', 'CPU count unavailable',
        ['preflight.cpu_unknown'] )
      : _ok_check('cpu_count');

    return ( $os_check, $backend_check, $cpu_check );
}

# The worker count the OS recommends, and the web processes Hypnotoad is
# given against what the CPUs can carry. Under cap-to-cpu that is the capped
# count: the walkthrough's 1-vCPU host, configured for 4 and run with 2, was
# reported as oversubscribed and refused by the unit's ExecStartPre.
sub _worker_checks ( $self, $context ) {
    my $recommended = $context->{os}{recommended_worker_count} || 0;
    my $cpu         = $context->{os}{cpu_count} || $MINIMUM_CPU_COUNT;
    my $per_cpu     = $context->{max_web_per_cpu};
    my $effective   = GPForum::Runtime->capped_web_processes(
        $context->{runtime}{web_processes},
        $cpu, $per_cpu, $context->{worker_policy},
    );

    my $recommended_check =
      $recommended < $MINIMUM_WORKER_COUNT ? _failed_check(
        'recommended_worker_count',
        'recommended worker count unavailable',
        ['preflight.workers_unknown']
      )
      : $recommended < $self->min_recommended_workers ? _degraded_check(
        'recommended_worker_count',
        'recommended worker count below configured threshold',
        [
            'preflight.workers_below',
            {
                recommended => $recommended,
                threshold   => $self->min_recommended_workers,
            }
        ]
      )
      : _ok_check('recommended_worker_count');
    my $web_check =
      defined $effective && $effective > $cpu * $per_cpu
      ? _degraded_check(
        'web_processes',
        'configured web processes exceed CPU-based conservative limit',
        [
            'preflight.web_over',
            {
                processes => $effective,
                limit     => $cpu * $per_cpu,
                cpus      => $cpu,
            }
        ]
      )
      : _ok_check('web_processes');

    return ( $recommended_check, $web_check );
}

# The descriptors open now, the limit on them, and how much of it is used.
sub _file_descriptor_checks ( $self, $context ) {
    my $resources = $context->{os}{resources} || {};
    my $open      = $resources->{open_file_descriptors};
    my $limit     = $resources->{file_descriptor_limit};
    my $minimum   = $self->minimum_file_descriptor_limit;

    my $open_check =
      !defined $open ? _degraded_check(
        'open_file_descriptors',
        'open file descriptor count unavailable',
        ['preflight.open_unknown']
      )
      : $open > $self->max_open_file_descriptors ? _degraded_check(
        'open_file_descriptors',
        'open file descriptor count exceeds configured threshold',
        [
            'preflight.open_over',
            { open => $open, maximum => $self->max_open_file_descriptors }
        ]
      )
      : _ok_check('open_file_descriptors');
    my $limit_check =
      defined $limit && $limit < $minimum
      ? _degraded_check(
        'file_descriptor_limit',
        'file descriptor limit is below recommended deployment floor',
        [ 'preflight.limit_low', { limit => $limit, minimum => $minimum } ]
      )
      : _ok_check('file_descriptor_limit');
    my $usage_check =
         defined $limit
      && defined $open && $open / $limit > $FD_USAGE_DEGRADED_RATIO
      ? _degraded_check(
        'file_descriptor_usage',
        'open file descriptor usage is above 80 percent',
        [
            'preflight.usage_high',
            { open => $open, limit => $limit, minimum => $minimum }
        ]
      )
      : _ok_check('file_descriptor_usage');

    return ( $open_check, $limit_check, $usage_check );
}

sub _swap_pressure_check ($context) {
    my $swap = ( $context->{os}{resources} || {} )->{swap_pressure} || {};
    return _degraded_check( 'swap_pressure', 'swap usage is high',
        ['preflight.swap_high'] )
      if ( $swap->{status} || q{} ) eq 'high';
    return _degraded_check(
        'swap_pressure',
        'swap usage is elevated',
        ['preflight.swap_elevated']
    ) if ( $swap->{status} || q{} ) eq 'warning';

    return _ok_check('swap_pressure');
}

# A feature set to "on" that the OS cannot give: reuseport needs
# SO_REUSEPORT, sendfile and X-Sendfile need sendfile.
sub _feature_support_check ($context) {
    for my $feature (@SUPPORT_GATED_FEATURES) {
        my $entry = $context->{features}{$feature} || {};
        next if ( $entry->{setting} || q{} ) ne $FEATURE_ON;

        my $supported =
            $feature eq 'reuseport'
          ? $context->{os}{supports_reuseport}
          : $context->{os}{supports_sendfile};
        return _degraded_check(
            'features',
            "$feature explicitly requested but unsupported",
            [
                'preflight.feature_unsupported',
                {
                    feature  => $feature,
                    variable => 'GPFORUM_OS_' . uc $feature,
                }
            ]
        ) if !$supported;
    }

    return _ok_check('features');
}

sub _recommendations ($self) {
    return {
        ulimit_nofile => {
            recommended_minimum => $self->minimum_file_descriptor_limit,
            rationale => 'web sockets, DB handles, logs, uploads, and workers',
        },
        postgresql => {
            application_name  => 'gpforum',
            statement_timeout =>
              'GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS on connect (0 disables)',
            idle_in_transaction_session_timeout =>
              'GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS on connect',
            lock_timeout =>
              'GPFORUM_DATABASE_LOCK_TIMEOUT_MS on connect; migrate keeps it',
            sslmode => 'prefer in development, require in production',
        },
    };
}

sub _socket_policy_check ($context) {
    my $sockets = $context->{sockets};
    return _degraded_check(
        'sockets',
        'socket policy unavailable',
        ['preflight.sockets_unknown']
    ) if !%{$sockets};

    for my $name ( sort keys %{$sockets} ) {
        return _degraded_check(
            'sockets',
            "$name requested but unsupported",
            [ 'preflight.socket_unsupported', { socket => $name } ]
        ) if $sockets->{$name}{degraded};
    }

    return _ok_check('sockets');
}

sub _process_policy_check ($context) {
    my $processes = $context->{processes};
    return _degraded_check(
        'processes',
        'process policy unavailable',
        ['preflight.processes_unknown']
    ) if !$processes->{classes};

    return _ok_check('processes');
}

sub _overall_status ($checks) {
    for my $check ( @{$checks} ) {
        return $STATUS_FAIL if $check->{status} eq $STATUS_FAIL;
    }

    for my $check ( @{$checks} ) {
        return $STATUS_DEGRADED if $check->{status} eq $STATUS_DEGRADED;
    }

    return $STATUS_OK;
}

sub _ok_check ($name) {
    return { name => $name, status => $STATUS_OK };
}

sub _degraded_check ( $name, $reason, $sentence ) {
    return _check( $name, $STATUS_DEGRADED, $reason, $sentence );
}

sub _failed_check ( $name, $reason, $sentence ) {
    return _check( $name, $STATUS_FAIL, $reason, $sentence );
}

# A check that is not ok: its reason in English, as the JSON report has
# always said it, and the catalog key and values of the sentence an
# operator reads.
sub _check ( $name, $status, $reason, $sentence ) {
    my ( $key, $parameters ) = @{$sentence};

    return {
        name       => $name,
        status     => $status,
        reason     => $reason,
        key        => $key,
        parameters => $parameters // {},
    };
}

1;
