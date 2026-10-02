# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::StagingHostVerify;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Service::Operations::StagingHostVerify;

our $VERSION = '0.001';

const my %FLAG_OPTIONS => (
    '--help'    => 'help',
    '--json'    => 'format_json',
    '--human'   => 'format_human',
    '--systemd' => 'systemd',
);
const my %VALUE_OPTIONS => (
    '--env-file'      => 'env_file',
    '--unit-dir'      => 'unit_dir',
    '--nginx-conf'    => 'nginx_conf',
    '--base-url'      => 'base_url',
    '--metrics-token' => 'metrics_token',
    '--timeout'       => 'timeout',
);

has verify => undef;

# Misuse -- an option this command does not know, all its parser croaks for --
# is the documented usage exit: the usage on stderr, status 2, without the
# " at bin/... line N." croak used to leave on it. A check that stops with an
# exception instead of evidence is a failure: 1 with its reason, redacted, on
# stderr and, as JSON, evidence saying fail (Command::Usage). It used to be
# rethrown with die, and an uncaught exception exits 255, or with whatever $!
# held: 2, misuse, after a failed file lookup.
sub run ( $self, @arguments ) {
    my $options = eval { return _options(@arguments) };
    if ( !$options ) {
        return GPForum::Command::Usage->error( undef,
            GPForum::Command::Usage->trimmed($EVAL_ERROR) );
    }
    return _print_usage() if $options->{help};

    my $status = eval { return $self->_run($options) };
    return $status if defined $status;

    return GPForum::Command::Usage->evidence_failure( $EVAL_ERROR,
        $options->{format}, { check => 'staging_host_verify' } );
}

sub _run ( $self, $options ) {
    my $service  = $self->_service;
    my $evidence = $service->run($options);
    print $service->format_evidence( $evidence, $options->{format} )
      or croak 'failed to write staging-host-verify evidence';

    return $service->exit_status($evidence);
}

sub _service ($self) {
    return $self->verify if $self->verify;

    return GPForum::Service::Operations::StagingHostVerify->new;
}

sub _options (@arguments) {
    my %options = (
        format        => 'json',
        help          => 0,
        systemd       => 0,
        env_file      => undef,
        unit_dir      => undef,
        nginx_conf    => undef,
        base_url      => undef,
        metrics_token => $ENV{GPFORUM_METRICS_TOKEN},
        timeout       => undef,
    );

    while (@arguments) {
        _apply_option( \%options, shift @arguments, \@arguments );
    }

    return \%options;
}

sub _apply_option ( $options, $argument, $arguments ) {
    if ( exists $FLAG_OPTIONS{$argument} ) {
        _set_flag( $options, $FLAG_OPTIONS{$argument} );
        return;
    }
    if ( exists $VALUE_OPTIONS{$argument} ) {
        _set_value( $options, $VALUE_OPTIONS{$argument}, $arguments );
        return;
    }

    croak "Unknown option: $argument\n" . _usage();
}

sub _set_flag ( $options, $name ) {
    my %handlers = (
        help         => sub { $options->{help}    = 1 },
        format_json  => sub { $options->{format}  = 'json' },
        format_human => sub { $options->{format}  = 'human' },
        systemd      => sub { $options->{systemd} = 1 },
    );
    my $handler = $handlers{$name};
    croak _usage() if !$handler;
    $handler->();

    return;
}

sub _set_value ( $options, $name, $arguments ) {
    my $value = shift @{$arguments};
    croak "Missing value for --"
      . (
          $name eq 'env_file'      ? 'env-file'
        : $name eq 'unit_dir'      ? 'unit-dir'
        : $name eq 'nginx_conf'    ? 'nginx-conf'
        : $name eq 'base_url'      ? 'base-url'
        : $name eq 'metrics_token' ? 'metrics-token'
        :                            $name
      )
      . "\n"
      . _usage()
      if !_has_text($value);

    if ( $name eq 'timeout' ) {
        croak "Invalid --timeout\n" . _usage()
          if $value !~ /\A[[:digit:]]+\z/msx;
        $options->{timeout} = 0 + $value;
        return;
    }

    $options->{$name} = $value;

    return;
}

sub _print_usage {
    print _usage() or croak 'failed to write usage';

    return 0;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-staging-host-verify [options]

Non-destructive staging host verify. Always checks in-repo deploy/runbook
artifacts. Optionally probes env-file key presence (values never printed),
systemd unit activity, installed unit-file contracts, installed nginx site
contracts, HTTP /health and /metrics, and https TLS scheme observe when
--base-url is https. Does not install units, reload nginx, or start
Hypnotoad. Does not claim private-beta readiness.

  --json                 evidence as JSON (default)
  --human                short plain-text evidence
  --env-file PATH        require key presence in staging env file
  --unit-dir DIR         observe installed unit files against deploy contract
  --nginx-conf PATH      observe installed nginx site against deploy contract
  --systemd              probe systemctl is-active for gpforum units
  --base-url URL         probe /health/live and /health/ready (+ TLS observe)
  --metrics-token TOKEN  also probe /metrics (or GPFORUM_METRICS_TOKEN)
  --timeout SECONDS      HTTP timeout (default 5)
  --help                 show this help
USAGE
}

sub _has_text ($value) {
    return defined $value && length $value;
}

1;

__END__

=head1 NAME

GPForum::Command::StagingHostVerify - Staging host bring-up verify CLI.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::StagingHostVerify->new->run(@ARGV);

=head1 DESCRIPTION

Operator CLI for non-destructive staging host verification.

=head1 DIAGNOSTICS

Misuse exits 2 with the usage on standard error. An error the verify raises
instead of reporting exits 1 with its reason, redacted, on standard error
and, with C<--json> (the default), evidence on standard output with
C<status> C<fail> and the reason in C<error>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
