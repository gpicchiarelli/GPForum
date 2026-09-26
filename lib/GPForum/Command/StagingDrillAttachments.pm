# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::StagingDrillAttachments;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Service::Operations::AttachmentFilesystemDrill;
use GPForum::Service::Operations::DeployChecklistDrill;
use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;
const my %FLAG_OPTIONS => (
    '--help'             => 'help',
    '--json'             => 'format_json',
    '--human'            => 'format_human',
    '--attachments-only' => 'attachments_only',
    '--deploy-only'      => 'deploy_only',
    '--skip-attachments' => 'skip_attachments',
    '--skip-deploy'      => 'skip_deploy',
);

has attachment_drill => undef;
has deploy_drill     => undef;

# A usage croak becomes the documented usage exit instead of an uncaught
# exception: same text, on stderr, status 2, without croak's " at FILE line N".
# Anything else is rethrown, so a real failure is not relabelled as misuse.
sub run ( $self, @arguments ) {
    my $status = eval { return $self->_run(@arguments); };
    return $status if defined $status;

    my $error = GPForum::Command::Usage->trimmed($EVAL_ERROR);
    if ( !GPForum::Command::Usage->is_usage($error) ) {
        die "$error\n";
    }

    return GPForum::Command::Usage->error( undef, $error );
}

sub _run ( $self, @arguments ) {
    my $options = eval { return _options(@arguments) };
    if ( !$options ) {
        print {*STDERR} _trim($EVAL_ERROR)
          or croak 'failed to write staging drill attachments usage error';
        return $EXIT_USAGE;
    }
    return _print_usage() if $options->{help};

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

sub _combined_status ($evidence) {
    my @statuses;
    for my $phase (qw(attachments_phase deploy_phase)) {
        my $status = $evidence->{$phase}{status} // q{};
        next if $status eq 'skipped';
        push @statuses, $status;
    }

    return _status_from_list( \@statuses );
}

sub _status_from_list ($statuses) {
    return 'fail'     if _list_has_fail($statuses);
    return 'degraded' if _list_has_degraded($statuses);

    return 'pass';
}

sub _list_has_fail ($statuses) {
    for my $status ( @{$statuses} ) {
        return 1 if $status eq 'fail';
        return 1 if $status ne 'pass' && $status ne 'degraded';
    }

    return 0;
}

sub _list_has_degraded ($statuses) {
    for my $status ( @{$statuses} ) {
        return 1 if $status eq 'degraded';
    }

    return 0;
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

    while (@arguments) {
        _apply_option( \%options, shift @arguments );
    }
    _normalize_phase_flags( \%options );

    return \%options;
}

sub _apply_option ( $options, $argument ) {
    if ( exists $FLAG_OPTIONS{$argument} ) {
        _set_flag( $options, $FLAG_OPTIONS{$argument} );
        return;
    }

    croak "Unknown option: $argument\n" . _usage();
}

sub _set_flag ( $options, $name ) {
    my %handlers = (
        help             => sub { $options->{help}             = 1 },
        format_json      => sub { $options->{format}           = 'json' },
        format_human     => sub { $options->{format}           = 'human' },
        attachments_only => sub { $options->{attachments_only} = 1 },
        deploy_only      => sub { $options->{deploy_only}      = 1 },
        skip_attachments => sub { $options->{skip_attachments} = 1 },
        skip_deploy      => sub { $options->{skip_deploy}      = 1 },
    );
    my $handler = $handlers{$name};
    croak _usage() if !$handler;
    $handler->();

    return;
}

sub _normalize_phase_flags ($options) {
    if ( $options->{attachments_only} && $options->{deploy_only} ) {
        croak "Cannot combine --attachments-only with --deploy-only\n"
          . _usage();
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
    $options->{run_attachments} = 0 if $options->{skip_attachments};
    $options->{run_deploy}      = 0 if $options->{skip_deploy};
    if ( !$options->{run_attachments} && !$options->{run_deploy} ) {
        croak "Nothing to run; enable attachments and/or deploy checks\n"
          . _usage();
    }

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

sub _trim ($error) {
    $error = "$error";
    $error =~ s/\s+\z//msx;

    return "$error\n";
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

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
