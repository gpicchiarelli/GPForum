# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::Preflight;

use strict;
use warnings;

use Const::Fast;
use JSON::MaybeXS;
use Mojo::Base -base, -signatures;

use GPForum::OS;

our $VERSION = '0.001';

const my $UNKNOWN_OS                      => 'unknown';
const my $SELECT_BACKEND                  => 'select';
const my $MINIMUM_CPU_COUNT               => 1;
const my $MINIMUM_WORKER_COUNT            => 1;
const my $DEFAULT_MINIMUM_FD_LIMIT        => 65_536;
const my $DEFAULT_MAX_OPEN_FDS            => 65_536;
const my $DEFAULT_MAX_WEB_PER_CPU         => 2;
const my $DEFAULT_MIN_RECOMMENDED_WORKERS => 1;
const my $STATUS_OK                       => 'ok';
const my $STATUS_DEGRADED                 => 'degraded';
const my $STATUS_FAIL                     => 'fail';
const my $FEATURE_ON                      => 'on';
const my @SUPPORT_GATED_FEATURES => qw(reuseport sendfile static_xsendfile);

has os                            => sub { return GPForum::OS->detect; };
has os_feature_settings           => sub { return {}; };
has profile                       => undef;
has min_recommended_workers       => $DEFAULT_MIN_RECOMMENDED_WORKERS;
has max_open_file_descriptors     => $DEFAULT_MAX_OPEN_FDS;
has minimum_file_descriptor_limit => $DEFAULT_MINIMUM_FD_LIMIT;
has max_web_processes_per_cpu     => $DEFAULT_MAX_WEB_PER_CPU;

sub from_runtime ( $class, $runtime, %options ) {
    return $class->new(
        profile => $runtime ? $runtime->as_hash : undef,
        %options,
    );
}

sub report ($self) {
    my $profile = $self->_profile;
    my $context = {
        os        => $profile->{os} || {},
        runtime   => _runtime_from_profile($profile),
        features  => $profile->{os_features}  || {},
        sockets   => $profile->{os_sockets}   || {},
        processes => $profile->{os_processes} || {},
    };
    my @checks = $self->_checks($context);

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

sub human_text ($self) {
    return join( "\n", @{ $self->human_lines } ) . "\n";
}

sub human_lines ($self) {
    my $report = $self->report;
    return [
        'GPForum OS preflight',
        'status=' . $report->{status},
        _os_line($report),
        _runtime_line($report),
        _resource_line($report),
        _recommendation_line($report),
        @{ _feature_lines($report) },
        @{ _socket_lines($report) },
        @{ _process_lines($report) },
        @{ _check_lines($report) },
    ];
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

sub _checks ( $self, $context ) {
    return (
        _os_check($context),
        _event_backend_check($context),
        _cpu_check($context),
        $self->_recommended_worker_check($context),
        $self->_web_worker_check($context),
        $self->_open_file_descriptor_check($context),
        $self->_file_descriptor_limit_check($context),
        $self->_file_descriptor_usage_check($context),
        _swap_pressure_check($context),
        _feature_support_check($context),
        _socket_policy_check($context),
        _process_policy_check($context),
    );
}

sub _runtime_from_profile ($profile) {
    return {
        web_processes      => $profile->{web_processes},
        worker_processes   => $profile->{worker_processes},
        realtime_processes => $profile->{realtime_processes},
    };
}

sub _os_check ($context) {
    my $name = $context->{os}{name};
    return _failed_check( 'os', 'OS profile missing' ) if !$name;
    return _degraded_check( 'os', 'unknown OS uses conservative mode' )
      if $name eq $UNKNOWN_OS;

    return _ok_check('os');
}

sub _event_backend_check ($context) {
    my $backend = $context->{os}{event_backend};
    return _failed_check( 'event_backend', 'event backend missing' )
      if !$backend;
    return _degraded_check( 'event_backend', 'select backend is conservative' )
      if $backend eq $SELECT_BACKEND;

    return _ok_check('event_backend');
}

sub _cpu_check ($context) {
    my $count = $context->{os}{cpu_count} || 0;
    return _failed_check( 'cpu_count', 'CPU count unavailable' )
      if $count < $MINIMUM_CPU_COUNT;

    return _ok_check('cpu_count');
}

sub _recommended_worker_check ( $self, $context ) {
    my $count = $context->{os}{recommended_worker_count} || 0;
    return _failed_check( 'recommended_worker_count',
        'recommended worker count unavailable' )
      if $count < $MINIMUM_WORKER_COUNT;
    return _degraded_check( 'recommended_worker_count',
        'recommended worker count below configured threshold' )
      if $count < $self->min_recommended_workers;

    return _ok_check('recommended_worker_count');
}

sub _web_worker_check ( $self, $context ) {
    my $configured = $context->{runtime}{web_processes};
    return _ok_check('web_processes') if !defined $configured;

    my $cpu = $context->{os}{cpu_count} || $MINIMUM_CPU_COUNT;
    my $max = $cpu * $self->max_web_processes_per_cpu;
    return _degraded_check( 'web_processes',
        'configured web processes exceed CPU-based conservative limit' )
      if $configured > $max;

    return _ok_check('web_processes');
}

sub _open_file_descriptor_check ( $self, $context ) {
    my $resources = $context->{os}{resources} || {};
    return _degraded_check( 'open_file_descriptors',
        'open file descriptor count unavailable' )
      if !defined $resources->{open_file_descriptors};
    return _degraded_check( 'open_file_descriptors',
        'open file descriptor count exceeds configured threshold' )
      if $resources->{open_file_descriptors} > $self->max_open_file_descriptors;

    return _ok_check('open_file_descriptors');
}

sub _file_descriptor_limit_check ( $self, $context ) {
    my $resources = $context->{os}{resources} || {};
    return _ok_check('file_descriptor_limit')
      if !defined $resources->{file_descriptor_limit};
    return _degraded_check( 'file_descriptor_limit',
        'file descriptor limit is below recommended deployment floor' )
      if $resources->{file_descriptor_limit} <
      $self->minimum_file_descriptor_limit;

    return _ok_check('file_descriptor_limit');
}

sub _file_descriptor_usage_check ( $self, $context ) {
    my $resources = $context->{os}{resources} || {};
    return _ok_check('file_descriptor_usage')
      if !defined $resources->{file_descriptor_limit}
      || !defined $resources->{open_file_descriptors};

    my $ratio =
      $resources->{open_file_descriptors} / $resources->{file_descriptor_limit};
    return _degraded_check( 'file_descriptor_usage',
        'open file descriptor usage is above 80 percent' )
      if $ratio > 0.8;

    return _ok_check('file_descriptor_usage');
}

sub _swap_pressure_check ($context) {
    my $swap = ( $context->{os}{resources} || {} )->{swap_pressure} || {};
    return _degraded_check( 'swap_pressure', 'swap usage is high' )
      if ( $swap->{status} || q{} ) eq 'high';
    return _degraded_check( 'swap_pressure', 'swap usage is elevated' )
      if ( $swap->{status} || q{} ) eq 'warning';

    return _ok_check('swap_pressure');
}

sub _feature_support_check ($context) {
    for my $feature (@SUPPORT_GATED_FEATURES) {
        my $entry = $context->{features}{$feature} || {};
        return _degraded_check( 'features',
            "$feature explicitly requested but unsupported" )
          if _feature_is_unsupported_request( $context, $feature, $entry );
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
    return _degraded_check( 'sockets', 'socket policy unavailable' )
      if !%{$sockets};

    for my $name ( sort keys %{$sockets} ) {
        return _degraded_check( 'sockets', "$name requested but unsupported" )
          if $sockets->{$name}{degraded};
    }

    return _ok_check('sockets');
}

sub _process_policy_check ($context) {
    my $processes = $context->{processes};
    return _degraded_check( 'processes', 'process policy unavailable' )
      if !$processes->{classes};

    return _ok_check('processes');
}

sub _feature_is_unsupported_request ( $context, $feature, $entry ) {
    return 0 if ( $entry->{setting} || q{} ) ne $FEATURE_ON;

    return !$context->{os}{supports_reuseport} if $feature eq 'reuseport';

    return !$context->{os}{supports_sendfile};
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

sub _degraded_check ( $name, $reason ) {
    return {
        name   => $name,
        status => $STATUS_DEGRADED,
        reason => $reason,
    };
}

sub _failed_check ( $name, $reason ) {
    return {
        name   => $name,
        status => $STATUS_FAIL,
        reason => $reason,
    };
}

sub _os_line ($report) {
    my $os = $report->{os};
    return join q{ },
      'os=' .                  ( $os->{name}                     || 'unknown' ),
      'event_backend=' .       ( $os->{event_backend}            || 'unknown' ),
      'cpu_count=' .           ( $os->{cpu_count}                || 'unknown' ),
      'recommended_workers=' . ( $os->{recommended_worker_count} || 'unknown' );
}

sub _runtime_line ($report) {
    my $runtime = $report->{runtime};
    return join q{ },
      'runtime',
      'web_processes=' . _known_or_unknown( $runtime->{web_processes} ),
      'worker_processes=' . _known_or_unknown( $runtime->{worker_processes} ),
      'realtime_processes='
      . _known_or_unknown( $runtime->{realtime_processes} );
}

sub _resource_line ($report) {
    my $resources = $report->{resources};
    return join q{ },
      'resources',
      'open_file_descriptors='
      . _known_or_unknown( $resources->{open_file_descriptors} ),
      'file_descriptor_limit='
      . _known_or_unknown( $resources->{file_descriptor_limit} ),
      'swap_pressure='
      . _known_or_unknown( ( $resources->{swap_pressure} || {} )->{status} );
}

sub _recommendation_line ($report) {
    return join q{ },
      'recommendations',
      'ulimit_nofile_min='
      . $report->{recommendations}{ulimit_nofile}{recommended_minimum},
      'postgresql=statement_timeout,idle_transaction_timeout,lock_timeout';
}

sub _feature_lines ($report) {
    return [
        map { _feature_line( $_, $report->{features}{$_} ) }
        sort keys %{ $report->{features} }
    ];
}

sub _socket_lines ($report) {
    return [
        map { _named_state_line( 'socket', $_, $report->{sockets}{$_} ) }
        sort keys %{ $report->{sockets} }
    ];
}

sub _process_lines ($report) {
    my $classes = $report->{processes}{classes} || {};
    return [
        map { _process_line( $_, $classes->{$_} ) }
        sort keys %{$classes}
    ];
}

sub _check_lines ($report) {
    return [ map { _check_line($_) } @{ $report->{checks} } ];
}

sub _named_state_line ( $prefix, $name, $entry ) {
    return join q{ },
      "$prefix=$name",
      'setting=' . _known_or_unknown( $entry->{setting} ),
      'supported=' . _known_or_unknown( $entry->{supported} ),
      'enabled=' . _known_or_unknown( $entry->{enabled} ),
      'degraded=' . _known_or_unknown( $entry->{degraded} );
}

sub _feature_line ( $name, $entry ) {
    return join q{ },
      "feature=$name",
      'setting=' . _known_or_unknown( $entry->{setting} ),
      'enabled=' . _known_or_unknown( $entry->{enabled} );
}

sub _process_line ( $name, $entry ) {
    return join q{ },
      "process=$name",
      'nice_delta=' . _known_or_unknown( $entry->{nice_delta} ),
      'enabled=' . _known_or_unknown( $entry->{enabled} ),
      'action=' . _known_or_unknown( $entry->{action} );
}

sub _check_line ($check) {
    my $line = join q{ },
      'check=' . $check->{name},
      'status=' . $check->{status};

    return $line if !$check->{reason};

    return $line . ' reason=' . $check->{reason};
}

sub _known_or_unknown ($value) {
    return defined $value ? $value : 'unknown';
}

1;
