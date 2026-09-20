package GPForum::Command::StagingDrillAttachments;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Service::Operations::AttachmentFilesystemDrill;
use GPForum::Service::Operations::DeployChecklistDrill;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;
const my %FLAG_OPTIONS => (
    '--help'              => 'help',
    '--json'              => 'format_json',
    '--human'             => 'format_human',
    '--attachments-only'  => 'attachments_only',
    '--deploy-only'       => 'deploy_only',
    '--skip-attachments'  => 'skip_attachments',
    '--skip-deploy'       => 'skip_deploy',
);

has attachment_drill => undef;
has deploy_drill     => undef;

sub run {
    my ( $self, @arguments ) = @_;

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

sub _run_phases {
    my ( $self, $options ) = @_;

    my %evidence = (
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
        push @{ $evidence{residual_gaps} },
          @{ $deploy->{residual_gaps} // [] };
    }
    else {
        $evidence{deploy_phase} = {
            status => 'skipped',
            reason => 'operator skipped deploy checklist drill',
        };
    }

    $evidence{residual_gaps} = _unique_gaps( $evidence{residual_gaps} );
    $evidence{status}        = _combined_status( \%evidence );

    return \%evidence;
}

sub _format {
    my ( $self, $evidence, $format ) = @_;

    if ( $format eq 'json' ) {
        require JSON::MaybeXS;
        return JSON::MaybeXS::encode_json($evidence) . "\n";
    }

    my @lines =
      ( 'staging-drill-attachments status=' . ( $evidence->{status} // 'fail' )
      );
    push @lines,
      _phase_line( 'attachments', $evidence->{attachments_phase} );
    push @lines, _phase_line( 'deploy', $evidence->{deploy_phase} );
    if ( _has_text( $evidence->{error} ) ) {
        push @lines, 'error=' . $evidence->{error};
    }

    return join( "\n", @lines ) . "\n";
}

sub _phase_line {
    my ( $name, $phase ) = @_;

    return "$name status=missing" if !$phase;

    my $status = $phase->{status} // 'fail';
    if ( $name eq 'attachments' && $phase->{attachments} ) {
        return
            "$name status=$status files="
          . ( $phase->{attachments}{files} // 0 );
    }
    if ( $name eq 'deploy' && $phase->{deploy_checklist} ) {
        return "$name status=$status mode=static_template";
    }

    return "$name status=$status";
}

sub _exit_status {
    my ( $self, $evidence ) = @_;

    return 0 if ( $evidence->{status} // q{} ) eq 'pass';

    return 1;
}

sub _combined_status {
    my ($evidence) = @_;

    for my $phase (qw(attachments_phase deploy_phase)) {
        my $status = $evidence->{$phase}{status} // q{};
        next if $status eq 'skipped';
        return 'fail' if $status ne 'pass';
    }

    return 'pass';
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

sub _attachment_service {
    my ($self) = @_;

    return $self->attachment_drill if $self->attachment_drill;

    return GPForum::Service::Operations::AttachmentFilesystemDrill->new;
}

sub _deploy_service {
    my ($self) = @_;

    return $self->deploy_drill if $self->deploy_drill;

    return GPForum::Service::Operations::DeployChecklistDrill->new;
}

sub _options {
    my (@arguments) = @_;

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

sub _apply_option {
    my ( $options, $argument ) = @_;

    if ( exists $FLAG_OPTIONS{$argument} ) {
        _set_flag( $options, $FLAG_OPTIONS{$argument} );
        return;
    }

    croak "Unknown option: $argument\n" . _usage();
}

sub _set_flag {
    my ( $options, $name ) = @_;

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

sub _normalize_phase_flags {
    my ($options) = @_;

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

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-staging-drill-attachments [options]

Rehearses attachment filesystem backup/restore on a throwaway tree and
statically validates nginx/systemd deploy templates. Does not require
PostgreSQL. Does not claim private-beta readiness.

  --json                 evidence as JSON (default)
  --human                short plain-text evidence
  --attachments-only     run only the attachment filesystem drill
  --deploy-only          run only the deploy checklist drill
  --skip-attachments     skip attachment filesystem drill
  --skip-deploy          skip deploy checklist drill
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

GPForum::Command::StagingDrillAttachments - Attachment restore and deploy checklist drills.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::StagingDrillAttachments->new->run(@ARGV);

=head1 DESCRIPTION

Operator CLI for throwaway attachment filesystem backup/restore and static
nginx/systemd template validation.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
