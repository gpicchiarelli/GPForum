package GPForum::Service::Operations::StagingHostVerify;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use IPC::Open3    qw(open3);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base;
use Mojo::File qw(path);
use Mojo::UserAgent;
use Symbol qw(gensym);

our $VERSION = '0.001';

const my $EXIT_FAILURE     => 1;
const my $EXIT_SHIFT       => 8;
const my $REPO_ROOT_MARKER => 'cpanfile';
const my $ROOT_WALK_LIMIT  => 8;
const my $DEFAULT_TIMEOUT  => 5;
const my $HTTP_OK_MIN      => 200;
const my $HTTP_OK_MAX      => 399;
const my @REQUIRED_ENV_KEYS => qw(
  GPFORUM_SESSION_SECRET
  GPFORUM_DATABASE_DSN
  GPFORUM_DATABASE_USER
  GPFORUM_METRICS_TOKEN
);
const my @SYSTEMD_UNITS => qw(
  gpforum.service
  gpforum-outbox.service
);
const my @REPO_ARTIFACTS => (
    'deploy/systemd/gpforum.service',
    'deploy/systemd/gpforum-outbox.service',
    'deploy/nginx/gpforum.conf',
    'script/gpforum-carton',
    'bin/gpforum',
    'docs/ops/staging-host.md',
    'docs/ops/staging-drills.md',
    'docs/ops/mail-check.md',
    'docs/ops/stress-load.md',
);
const my $RESIDUAL_LIVE =>
'Live systemd install, nginx reload, Hypnotoad start, and TLS termination remain operator steps; archive verify JSON from the staging host.';
const my $RESIDUAL_BETA =>
  'This verify does not claim private-beta readiness by itself.';
const my $RESIDUAL_EVIDENCE =>
'Archive mail-check, stress-load, and staging-drill evidence beside this verify on the staging target.';

has repo_root  => sub { return _detect_repo_root() };
has user_agent => sub {
    return Mojo::UserAgent->new->max_redirects(0);
};

sub run {
    my ( $self, $options ) = @_;

    $options ||= {};
    my $evidence = {
        status        => undef,
        check         => 'staging_host_verify',
        residual_gaps => [],
    };

    my $ok = eval {
        $self->_execute( $evidence, $options );
        return 1;
    };
    if ( !$ok ) {
        $evidence->{status} = 'fail';
        $evidence->{error}  = _trim_error($EVAL_ERROR);
    }
    $evidence->{status} ||= _combined_status($evidence);
    $evidence->{residual_gaps}
      = _unique_gaps( [ @{ $evidence->{residual_gaps} // [] } ] );

    return $evidence;
}

sub format_evidence {
    my ( $self, $evidence, $format ) = @_;

    $format ||= 'json';
    return encode_json($evidence) . "\n" if $format eq 'json';

    return _human_evidence($evidence);
}

sub exit_status {
    my ( undef, $evidence ) = @_;

    my $status = $evidence->{status} // q{};
    return 0 if $status eq 'pass' || $status eq 'degraded';

    return $EXIT_FAILURE;
}

sub _execute {
    my ( $self, $evidence, $options ) = @_;

    $evidence->{prerequisites} = $self->_prerequisites_phase;
    push @{ $evidence->{residual_gaps} },
      @{ $evidence->{prerequisites}{residual_gaps} // [] };

    $evidence->{env_file} = $self->_env_file_phase($options);
    push @{ $evidence->{residual_gaps} },
      @{ $evidence->{env_file}{residual_gaps} // [] };

    $evidence->{systemd} = $self->_systemd_phase($options);
    push @{ $evidence->{residual_gaps} },
      @{ $evidence->{systemd}{residual_gaps} // [] };

    $evidence->{health} = $self->_health_phase($options);
    push @{ $evidence->{residual_gaps} },
      @{ $evidence->{health}{residual_gaps} // [] };

    $evidence->{tls} = $self->_tls_phase($options);
    push @{ $evidence->{residual_gaps} },
      @{ $evidence->{tls}{residual_gaps} // [] };

    push @{ $evidence->{residual_gaps} }, $RESIDUAL_LIVE, $RESIDUAL_BETA,
      $RESIDUAL_EVIDENCE;

    return;
}

sub _prerequisites_phase {
    my ($self) = @_;

    my $root = $self->repo_root;
    croak 'repository root not found' if !_has_text($root);

    my @artifacts;
    my @missing;
    for my $relative (@REPO_ARTIFACTS) {
        my $absolute = path( $root, $relative )->to_string;
        my $exists   = -f $absolute ? 1 : 0;
        push @artifacts,
          {
            path   => $relative,
            exists => $exists ? \1 : \0,
            status => $exists ? 'pass' : 'fail',
          };
        push @missing, $relative if !$exists;
    }

    return {
        status    => @missing ? 'fail' : 'pass',
        repo_root => $root,
        artifacts => \@artifacts,
        missing   => \@missing,
    };
}

sub _env_file_phase {
    my ( $self, $options ) = @_;

    my $path = $options->{env_file};
    if ( !_has_text($path) ) {
        return {
            status        => 'skipped',
            reason        => 'pass --env-file PATH to inspect staging env keys',
            residual_gaps => [
'Env-file key presence not checked; pass --env-file /etc/gpforum/gpforum.env on the staging host.'
            ],
        };
    }

    if ( !-f $path ) {
        return {
            status => 'fail',
            path   => $path,
            error  => 'env file missing',
        };
    }

    my $parsed = _parse_env_keys($path);
    my @present;
    my @absent;
    for my $key (@REQUIRED_ENV_KEYS) {
        if ( $parsed->{$key} ) {
            push @present, $key;
        }
        else {
            push @absent, $key;
        }
    }

    return {
        status          => @absent ? 'fail' : 'pass',
        path            => $path,
        required_keys   => [@REQUIRED_ENV_KEYS],
        present_keys    => \@present,
        missing_keys    => \@absent,
        values_redacted => \1,
        note => 'Only key names are reported; secret values are never copied',
    };
}

sub _parse_env_keys {
    my ($path) = @_;

    my %present;
    my $text = path($path)->slurp;
    for my $line ( split /\n/msx, $text ) {
        next if $line =~ /\A\s*\#/msx;
        next if $line !~ /\A\s*([A-Za-z_][A-Za-z0-9_]*)\s*=/msx;
        my $key   = $1;
        my $value = $line;
        $value =~ s/\A\s*[A-Za-z_][A-Za-z0-9_]*\s*=\s*//msx;
        $value =~ s/\A["']|["']\z//gmsx;
        $present{$key} = 1 if length $value;
    }

    return \%present;
}

sub _systemd_phase {
    my ( $self, $options ) = @_;

    if ( !$options->{systemd} ) {
        return {
            status        => 'skipped',
            reason        => 'pass --systemd to probe systemctl is-active',
            residual_gaps => [
'systemd unit activity not probed; pass --systemd on a host with systemctl.'
            ],
        };
    }

    my $binary = _which('systemctl');
    if ( !_has_text($binary) ) {
        return {
            status => 'skipped',
            reason => 'systemctl not on PATH',
            residual_gaps =>
              ['systemctl unavailable; live unit activity not verified'],
        };
    }

    my @units;
    for my $unit (@SYSTEMD_UNITS) {
        my $capture =
          _capture_command( [ $binary, 'is-active', '--quiet', $unit ] );
        my $active = $capture->{exit} == 0 ? 1 : 0;
        push @units,
          {
            name   => $unit,
            status => $active ? 'pass' : 'fail',
            active => $active ? \1 : \0,
            exit   => $capture->{exit},
            output => _trim_output( $capture->{output} ),
          };
    }

    my $failed = grep { $_->{status} eq 'fail' } @units;

    return {
        status    => $failed ? 'fail' : 'pass',
        available => \1,
        tool      => $binary,
        units     => \@units,
    };
}

sub _health_phase {
    my ( $self, $options ) = @_;

    my $base = $options->{base_url};
    if ( !_has_text($base) ) {
        return {
            status => 'skipped',
            reason => 'pass --base-url to probe /health/live and /health/ready',
            residual_gaps => [
'HTTP health not probed; pass --base-url https://staging.example after Hypnotoad+TLS is up.'
            ],
        };
    }

    $base =~ s{/\z}{}msx;
    my $timeout = $options->{timeout} // $DEFAULT_TIMEOUT;
    my $ua      = $self->user_agent;
    $ua->connect_timeout($timeout);
    $ua->request_timeout($timeout);

    my @endpoints = (
        { name => 'live',  path => '/health/live' },
        { name => 'ready', path => '/health/ready' },
    );

    my @results;
    for my $endpoint (@endpoints) {
        push @results, _probe_http( $ua, $base . $endpoint->{path},
            $endpoint->{name} );
    }

    my $metrics_token = $options->{metrics_token};
    if ( _has_text($metrics_token) ) {
        push @results,
          _probe_http(
            $ua,
            $base . '/metrics',
            'metrics',
            { 'X-GPForum-Metrics-Token' => $metrics_token },
          );
    }
    else {
        push @results,
          {
            name   => 'metrics',
            status => 'skipped',
            reason => 'pass --metrics-token to probe /metrics',
          };
    }

    my $failed = grep { $_->{status} eq 'fail' } @results;

    return {
        status    => $failed ? 'fail' : 'pass',
        base_url  => $base,
        endpoints => \@results,
    };
}

sub _tls_phase {
    my ( $self, $options ) = @_;

    my $base = $options->{base_url};
    if ( !_has_text($base) ) {
        return {
            status => 'skipped',
            reason => 'pass --base-url https://staging.example to observe TLS',
            residual_gaps => [
'TLS not observed; pass an https --base-url after staging TLS termination is up.'
            ],
        };
    }

    if ( $base =~ m{\Ahttp://}msxi ) {
        return {
            status  => 'skipped',
            scheme  => 'http',
            base_url => $base,
            reason  => 'base-url uses http; TLS termination not observed',
            residual_gaps => [
'--base-url is http; archive staging-host-verify against https://… for TLS evidence.'
            ],
        };
    }

    if ( $base !~ m{\Ahttps://}msxi ) {
        return {
            status => 'fail',
            reason => 'base-url must start with http:// or https://',
            base_url => $base,
        };
    }

    my $host_port = $base;
    $host_port =~ s{\Ahttps://}{}msxi;
    $host_port =~ s{/.*\z}{}msx;
    my ( $host, $port ) = split /:/msx, $host_port, 2;
    $port ||= '443';

    return {
        status   => 'pass',
        scheme   => 'https',
        base_url => $base,
        host     => $host,
        port     => 0 + $port,
        note =>
'Records https scheme for staging TLS evidence. Does not pin CAs, check HSTS, run ACME, or replace operator cert inventory. Pair with a successful health probe on the same --base-url.',
        residual_gaps => [
'Full ACME/cert-rotation evidence and reverse-proxy TLS config remain operator steps on the staging host.'
        ],
    };
}

sub _probe_http {
    my ( $ua, $url, $name, $headers ) = @_;

    my $tx = eval {
        my $built = $ua->build_tx( GET => $url );
        if ($headers) {
            for my $header ( keys %{$headers} ) {
                $built->req->headers->header( $header => $headers->{$header} );
            }
        }
        return $ua->start($built);
    };
    if ( !$tx || $EVAL_ERROR ) {
        return {
            name   => $name,
            url    => $url,
            status => 'fail',
            error  => _trim_error( $EVAL_ERROR || 'HTTP probe failed' ),
        };
    }
    if ( my $err = $tx->error ) {
        return {
            name   => $name,
            url    => $url,
            status => 'fail',
            error  => $err->{message} // 'transport error',
        };
    }

    my $code = $tx->res->code // 0;
    my $ok   = $code >= $HTTP_OK_MIN && $code <= $HTTP_OK_MAX;

    return {
        name        => $name,
        url         => $url,
        status      => $ok ? 'pass' : 'fail',
        http_status => $code,
    };
}

sub _combined_status {
    my ($evidence) = @_;

    my @statuses;
    for my $name (qw(prerequisites env_file systemd health tls)) {
        my $status = $evidence->{$name}{status} // q{};
        next if $status eq 'skipped';
        push @statuses, $status;
    }

    return 'fail' if grep { $_ eq 'fail' } @statuses;
    return 'degraded'
      if grep { $_ eq 'degraded' } @statuses;
    return 'pass' if @statuses;

    return 'pass';
}

sub _human_evidence {
    my ($evidence) = @_;

    my @lines = (
        'staging-host-verify status=' . ( $evidence->{status} // 'fail' ) );
    for my $name (qw(prerequisites env_file systemd health tls)) {
        my $phase = $evidence->{$name} // {};
        push @lines, "$name status=" . ( $phase->{status} // 'missing' );
    }
    if ( _has_text( $evidence->{error} ) ) {
        push @lines, 'error=' . $evidence->{error};
    }

    return join( "\n", @lines ) . "\n";
}

sub _capture_command {
    my ($command) = @_;

    my $stderr = gensym;
    my $pid    = open3( my $stdin, my $stdout, $stderr, @{$command} );
    close $stdin or croak 'failed to close staging-host-verify stdin';
    my $output = _slurp_handle($stdout) . _slurp_handle($stderr);
    waitpid $pid, 0;
    my $exit = $CHILD_ERROR >> $EXIT_SHIFT;

    return { ok => ( $exit == 0 ? 1 : 0 ), exit => $exit, output => $output };
}

sub _slurp_handle {
    my ($handle) = @_;

    my $output = q{};
    while ( my $line = <$handle> ) {
        $output .= $line;
    }
    close $handle or croak 'failed to close staging-host-verify handle';

    return $output;
}

sub _which {
    my ($name) = @_;

    for my $dir ( split /:/msx, ( $ENV{PATH} // q{} ) ) {
        my $candidate = path( $dir, $name )->to_string;
        return $candidate if -x $candidate;
    }

    return;
}

sub _detect_repo_root {
    my $start  = path(__FILE__)->realpath->dirname;
    my $cursor = $start;
    for ( 1 .. $ROOT_WALK_LIMIT ) {
        return $cursor->to_string
          if -f $cursor->child($REPO_ROOT_MARKER)->to_string;
        last if $cursor->to_string eq $cursor->dirname->to_string;
        $cursor = $cursor->dirname;
    }

    return;
}

sub _unique_gaps {
    my ($gaps) = @_;

    my %seen;
    my @unique;
    for my $gap ( @{$gaps} ) {
        next if $seen{$gap}++;
        push @unique, $gap;
    }

    return \@unique;
}

sub _trim_error {
    my ($error) = @_;

    $error = "$error";
    $error =~ s/\s+\z//msx;

    return $error;
}

sub _trim_output {
    my ($output) = @_;

    $output //= q{};
    $output =~ s/\s+\z//msx;
    return $output if length $output <= 400;

    return substr( $output, 0, 400 ) . '…';
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::StagingHostVerify - Non-destructive staging host verify.

=head1 VERSION

Version 0.001.

=head1 DESCRIPTION

Probes repository prerequisites and, when asked, staging env-file key presence
(values redacted), systemd unit activity, and HTTP health endpoints. Never
installs units, reloads nginx, or starts Hypnotoad.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
