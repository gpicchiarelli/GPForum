# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::StagingHostVerify;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Usage;
use GPForum::Service::Operations::StagingHostVerify;
use GPForum::X::Usage;

our $VERSION = '0.001';

# Each flag sets one option to one value.
const my %FLAG_OPTIONS => (
    '--help'    => [ help    => 1 ],
    '--json'    => [ format  => 'json' ],
    '--human'   => [ format  => 'human' ],
    '--systemd' => [ systemd => 1 ],
);
const my %VALUE_OPTIONS => (
    '--env-file'      => 'env_file',
    '--unit-dir'      => 'unit_dir',
    '--nginx-conf'    => 'nginx_conf',
    '--base-url'      => 'base_url',
    '--metrics-token' => 'metrics_token',
    '--timeout'       => 'timeout',
);

has verify => undef;    # optional: a test's double; else the real one

# Misuse -- an option this command does not know, all its parser rejects --
# is the documented usage exit: the usage on stderr, status 2, without the
# " at bin/... line N." croak used to leave on it. A check that stops with an
# exception instead of evidence is a failure: 1 with its reason, redacted, on
# stderr and, as JSON, evidence saying fail (Command::Usage). It used to be
# rethrown with die, and an uncaught exception exits 255, or with whatever $!
# held: 2, misuse, after a failed file lookup.
sub run ( $self, @arguments ) {
    my $options;
    try {
        $options = _options(@arguments);
    }
    catch ($error) {
        return GPForum::Command::Usage->error( undef,
            GPForum::Command::Usage->trimmed($error) );
    };

    return _print_usage() if $options->{help};

    my $status;
    try {
        $status = $self->_run($options);
    }
    catch ($error) {
        return GPForum::Command::Usage->evidence_failure( $error,
            $options->{format}, { check => 'staging_host_verify' } );
    };

    return $status;
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
        my $argument = shift @arguments;
        if ( exists $FLAG_OPTIONS{$argument} ) {
            my ( $name, $value ) = @{ $FLAG_OPTIONS{$argument} };
            $options{$name} = $value;
            next;
        }
        if ( !exists $VALUE_OPTIONS{$argument} ) {
            GPForum::X::Usage->throw(
                message => "Unknown option: $argument\n" . _usage() );
        }

        my $value = shift @arguments;
        if ( !_has_text($value) ) {
            GPForum::X::Usage->throw(
                message => "Missing value for $argument\n" . _usage() );
        }
        if ( $argument eq '--timeout' ) {
            if ( $value !~ /\A[[:digit:]]+\z/msx ) {
                GPForum::X::Usage->throw(
                    message => "Invalid --timeout\n" . _usage() );
            }
            $value = 0 + $value;
        }
        $options{ $VALUE_OPTIONS{$argument} } = $value;
    }

    return \%options;
}

sub _print_usage {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() );
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
artifacts. Optionally checks every setting in the env file as the service
does at its start, as gpforum doctor does (values never printed), systemd
unit activity, installed unit-file contracts, installed nginx site
contracts, HTTP /health and /metrics, and https TLS scheme observe when
--base-url is https. Does not install units, reload nginx, or start
Hypnotoad. Does not claim private-beta readiness.

  --json                 evidence as JSON (default)
  --human                short plain-text evidence
  --env-file PATH        check every setting in the staging env file
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

=head1 SUBROUTINES/METHODS

=head2 verify

The verification to run; a test passes a double. Without one, a
L<GPForum::Service::Operations::StagingHostVerify>.

=head2 run

Runs the command with its arguments; returns the exit status.

=head2 usage_text

The usage text, for the front door.

=head1 DIAGNOSTICS

Misuse exits 2 with the usage on standard error. An error the verify raises
instead of reporting exits 1 with its reason, redacted, on standard error
and, with C<--json> (the default), evidence on standard output with
C<status> C<fail> and the reason in C<error>.

=head1 CONFIGURATION AND ENVIRONMENT

C<GPFORUM_METRICS_TOKEN>, when C<--metrics-token> is not given, and C<PATH>,
where C<systemctl> is looked for. Values read from the env file are never
printed.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::StagingHostVerify>,
L<GPForum::Command::Usage>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

It observes the host and changes nothing: it does not install units,
reload nginx or start Hypnotoad.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
