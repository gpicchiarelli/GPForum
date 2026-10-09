# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::StagingDrillAttachments;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Usage;
use GPForum::Service::Operations::AttachmentFilesystemDrill;
use GPForum::Service::Operations::DeployChecklistDrill;
use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);
use GPForum::X::Usage;

our $VERSION = '0.001';

# Each flag sets one option to one value.
const my %FLAG_OPTIONS => (
    '--help'             => [ help             => 1 ],
    '--json'             => [ format           => 'json' ],
    '--human'            => [ format           => 'human' ],
    '--attachments-only' => [ attachments_only => 1 ],
    '--deploy-only'      => [ deploy_only      => 1 ],
    '--skip-attachments' => [ skip_attachments => 1 ],
    '--skip-deploy'      => [ skip_deploy      => 1 ],
);

has attachment_drill => undef;  # optional: a test's double; else the real drill
has deploy_drill     => undef;  # optional: a test's double; else the real drill

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
        return GPForum::Command::Usage->evidence_failure(
            $error,
            $options->{format},
            {
                check => 'staging_ops_extensions',
                drill => 'staging_ops_extensions',
            }
        );
    };

    return $status;
}

sub _run ( $self, $options ) {
    my $evidence = $self->_run_phases($options);
    print $self->_format( $evidence, $options->{format} )
      or croak 'failed to write staging drill attachments evidence';

    return $self->_exit_status($evidence);
}

sub _run_phases ( $self, $options ) {
    my %evidence = (
        check         => 'staging_ops_extensions',
        status        => undef,
        drill         => 'staging_ops_extensions',
        residual_gaps => [],
    );

    if ( $options->{run_attachments} ) {
        my $attachments = $self->_attachment_service->run($options);
        $evidence{attachments_phase} = $attachments;
        push @{ $evidence{residual_gaps} },
          @{ $attachments->{residual_gaps} // [] };
    }
    else {
        $evidence{attachments_phase} = {
            status => 'skipped',
            reason => 'operator skipped attachment filesystem drill',
        };
    }

    if ( $options->{run_deploy} ) {
        my $deploy = $self->_deploy_service->run($options);
        $evidence{deploy_phase} = $deploy;
        push @{ $evidence{residual_gaps} }, @{ $deploy->{residual_gaps} // [] };
    }
    else {
        $evidence{deploy_phase} = {
            status => 'skipped',
            reason => 'operator skipped deploy checklist drill',
        };
    }

    $evidence{status} = _combined_status( \%evidence );

    return evidence_finalize( \%evidence );
}

sub _format ( $self, $evidence, $format ) {
    if ( $format eq 'json' ) {
        require JSON::MaybeXS;
        return JSON::MaybeXS::encode_json($evidence) . "\n";
    }

    my @lines =
      ( 'staging-drill-attachments status='
          . ( $evidence->{status} // 'fail' ) );
    push @lines, _phase_line( 'attachments', $evidence->{attachments_phase} );
    push @lines, _phase_line( 'deploy',      $evidence->{deploy_phase} );
    if ( _has_text( $evidence->{error} ) ) {
        push @lines, 'error=' . $evidence->{error};
    }

    return join( "\n", @lines ) . "\n";
}

sub _phase_line ( $name, $phase ) {
    return "$name status=missing" if !$phase;

    my $status = $phase->{status} // 'fail';
    if ( $name eq 'attachments' && $phase->{attachments} ) {
        return "$name status=$status files="
          . ( $phase->{attachments}{files} // 0 );
    }
    if ( $name eq 'deploy' && $phase->{deploy_checklist} ) {
        return _deploy_phase_line( $status, $phase->{deploy_checklist} );
    }

    return "$name status=$status";
}

sub _deploy_phase_line ( $status, $checklist ) {
    my $host = $checklist->{host_validation} // {};
    return
        "deploy status=$status mode="
      . ( $checklist->{mode} // 'static_plus_host' )
      . ' host='
      . ( $host->{status} // 'missing' );
}

sub _exit_status ( $self, $evidence ) {
    my $status = $evidence->{status} // q{};
    return 0 if $status eq 'pass';
    return 0 if $status eq 'degraded';

    return 1;
}

# A phase that ran and neither passed nor degraded -- failed, or answered
# with no status at all -- fails the drill; one that degraded degrades it.
sub _combined_status ($evidence) {
    my $combined = 'pass';
    for my $phase (qw(attachments_phase deploy_phase)) {
        my $status = $evidence->{$phase}{status} // q{};
        next          if $status eq 'skipped' || $status eq 'pass';
        return 'fail' if $status ne 'degraded';
        $combined = 'degraded';
    }

    return $combined;
}

sub _attachment_service ($self) {
    return $self->attachment_drill if $self->attachment_drill;

    return GPForum::Service::Operations::AttachmentFilesystemDrill->new;
}

sub _deploy_service ($self) {
    return $self->deploy_drill if $self->deploy_drill;

    return GPForum::Service::Operations::DeployChecklistDrill->new;
}

sub _options (@arguments) {
    my %options = (
        format           => 'json',
        help             => 0,
        run_attachments  => 1,
        run_deploy       => 1,
        attachments_only => 0,
        deploy_only      => 0,
        skip_attachments => 0,
        skip_deploy      => 0,
    );

    for my $argument (@arguments) {
        if ( !exists $FLAG_OPTIONS{$argument} ) {
            GPForum::X::Usage->throw(
                message => "Unknown option: $argument\n" . _usage() );
        }
        my ( $name, $value ) = @{ $FLAG_OPTIONS{$argument} };
        $options{$name} = $value;
    }
    _normalize_phase_flags( \%options );

    return \%options;
}

sub _normalize_phase_flags ($options) {
    if ( $options->{attachments_only} && $options->{deploy_only} ) {
        GPForum::X::Usage->throw(
            message => "Cannot combine --attachments-only with --deploy-only\n"
              . _usage() );
    }
    if ( $options->{attachments_only} ) {
        $options->{run_attachments} = 1;
        $options->{run_deploy}      = 0;
        return;
    }
    if ( $options->{deploy_only} ) {
        $options->{run_attachments} = 0;
        $options->{run_deploy}      = 1;
        return;
    }
    if ( $options->{skip_attachments} ) {
        $options->{run_attachments} = 0;
    }
    if ( $options->{skip_deploy} ) {
        $options->{run_deploy} = 0;
    }
    if ( !$options->{run_attachments} && !$options->{run_deploy} ) {
        GPForum::X::Usage->throw( message =>
              "Nothing to run; enable attachments and/or deploy checks\n"
              . _usage() );
    }

    return;
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
Usage: bin/gpforum-staging-drill-attachments [options]

Rehearses attachment filesystem backup/restore on a populated throwaway
var/attachments tree and validates nginx/systemd deploy templates
(static text always; systemd-analyze verify / nginx -t when those tools
are on PATH, otherwise host checks are skipped and status may be
degraded). Does not require PostgreSQL. Does not claim private-beta
readiness.

  --json                 evidence as JSON (default)
  --human                short plain-text evidence
  --attachments-only     run only the attachment filesystem drill
  --deploy-only          run only the deploy checklist drill
  --skip-attachments     skip attachment filesystem drill
  --skip-deploy          skip deploy checklist drill
  --help                 show this help
USAGE
}

sub _has_text ($value) {
    return defined $value && length $value;
}

1;

__END__

=head1 NAME

GPForum::Command::StagingDrillAttachments - Attachment restore and deploy checklist drills.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::StagingDrillAttachments->new->run(@ARGV);

=head1 DESCRIPTION

Operator CLI for populated C<var/attachments> filesystem backup/restore and
nginx/systemd template validation (static plus optional host
C<systemd-analyze verify> / C<nginx -t>).

=head1 SUBROUTINES/METHODS

=head2 attachment_drill

The attachment drill to run; a test passes a double. Without one, a
L<GPForum::Service::Operations::AttachmentFilesystemDrill>.

=head2 deploy_drill

The deploy checklist drill to run; a test passes a double. Without one, a
L<GPForum::Service::Operations::DeployChecklistDrill>.

=head2 run

Runs the command with its arguments; returns the exit status.

=head2 usage_text

The usage text, for the front door.

=head1 DIAGNOSTICS

Misuse exits 2 with the usage on standard error. An error the drill raises
instead of reporting exits 1 with its reason, redacted, on standard error
and, with C<--json> (the default), evidence on standard output with
C<status> C<fail> and the reason in C<error>.

=head1 CONFIGURATION AND ENVIRONMENT

C<PATH>, where the deploy drill looks for C<systemd-analyze> and C<nginx>.
No PostgreSQL is needed.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::AttachmentFilesystemDrill>,
L<GPForum::Service::Operations::DeployChecklistDrill>,
L<GPForum::Service::Operations::EvidenceMeta>, L<GPForum::Command::Usage>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Without C<systemd-analyze> or C<nginx> on C<PATH> the host checks are
skipped and the status may be C<degraded>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
