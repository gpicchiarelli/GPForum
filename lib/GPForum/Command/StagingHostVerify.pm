package GPForum::Command::StagingHostVerify;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Service::Operations::StagingHostVerify;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;
const my %FLAG_OPTIONS => (
    '--help'    => 'help',
    '--json'    => 'format_json',
    '--human'   => 'format_human',
    '--systemd' => 'systemd',
);
const my %VALUE_OPTIONS => (
    '--env-file'      => 'env_file',
    '--base-url'      => 'base_url',
    '--metrics-token' => 'metrics_token',
    '--timeout'       => 'timeout',
);

has verify => undef;

sub run {
    my ( $self, @arguments ) = @_;

    my $options = eval { return _options(@arguments) };
    if ( !$options ) {
        print {*STDERR} _trim($EVAL_ERROR)
          or croak 'failed to write staging-host-verify usage error';
        return $EXIT_USAGE;
    }
    return _print_usage() if $options->{help};

    my $service  = $self->_service;
    my $evidence = $service->run($options);
    print $service->format_evidence( $evidence, $options->{format} )
      or croak 'failed to write staging-host-verify evidence';

    return $service->exit_status($evidence);
}

sub _service {
    my ($self) = @_;

    return $self->verify if $self->verify;

    return GPForum::Service::Operations::StagingHostVerify->new;
}

sub _options {
    my (@arguments) = @_;

    my %options = (
        format         => 'json',
        help           => 0,
        systemd        => 0,
        env_file       => undef,
        base_url       => undef,
        metrics_token  => $ENV{GPFORUM_METRICS_TOKEN},
        timeout        => undef,
    );

    while (@arguments) {
        _apply_option( \%options, shift @arguments, \@arguments );
    }

    return \%options;
}

sub _apply_option {
    my ( $options, $argument, $arguments ) = @_;

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

sub _set_flag {
    my ( $options, $name ) = @_;

    my %handlers = (
        help         => sub { $options->{help}   = 1 },
        format_json  => sub { $options->{format} = 'json' },
        format_human => sub { $options->{format} = 'human' },
        systemd      => sub { $options->{systemd} = 1 },
    );
    my $handler = $handlers{$name};
    croak _usage() if !$handler;
    $handler->();

    return;
}

sub _set_value {
    my ( $options, $name, $arguments ) = @_;

    my $value = shift @{$arguments};
    croak "Missing value for --"
      . ( $name eq 'env_file'       ? 'env-file'
        : $name eq 'base_url'       ? 'base-url'
        : $name eq 'metrics_token'  ? 'metrics-token'
        :                             $name )
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

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-staging-host-verify [options]

Non-destructive staging host verify. Always checks in-repo deploy/runbook
artifacts. Optionally probes env-file key presence (values never printed),
systemd unit activity, and HTTP /health and /metrics. Does not install
units, reload nginx, or start Hypnotoad. Does not claim private-beta
readiness.

  --json                 evidence as JSON (default)
  --human                short plain-text evidence
  --env-file PATH        require key presence in staging env file
  --systemd              probe systemctl is-active for gpforum units
  --base-url URL         probe /health/live and /health/ready
  --metrics-token TOKEN  also probe /metrics (or GPFORUM_METRICS_TOKEN)
  --timeout SECONDS      HTTP timeout (default 5)
  --help                 show this help
USAGE
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value;
}

sub _trim {
    my ($error) = @_;

    $error = "$error";
    $error =~ s/\s+\z//msx;

    return "$error\n";
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

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
