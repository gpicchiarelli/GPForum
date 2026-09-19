package GPForum::Service::Privacy::Completion;

use strict;
use warnings;

use Const::Fast;
use GPForum::Service::Privacy::Record;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $JOB_DONE    => 'done';
const my $HOLD_REASON => 'active legal hold';

has record => sub { return GPForum::Service::Privacy::Record->new; };

sub job_done {
    my ( $self, $job ) = @_;

    my $status = $self->record->column( $job, 'status' ) || q{};
    return $status eq $JOB_DONE ? 1 : 0;
}

sub approval_replay {
    my ( $self, $request_id, $job ) = @_;

    return {
        idempotent => 1,
        job        => $self->record->job_hash($job),
        ok         => 1,
        request_id => $request_id,
    };
}

sub completion_replay {
    my ( undef, $erasure_job_id ) = @_;

    return {
        erasure_job_id => $erasure_job_id,
        idempotent     => 1,
        ok             => 1,
    };
}

sub skipped {
    my ( undef, $reason ) = @_;

    return { skipped => $reason };
}

sub hold_reason {
    my ( undef, $reason ) = @_;

    if ( defined $reason && length $reason ) {
        return $reason;
    }

    return $HOLD_REASON;
}

1;

__END__

=head1 NAME

GPForum::Service::Privacy::Completion - Approval and erasure replay hashes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $replay = $completion->approval_replay( $request_id, $job );

=head1 DESCRIPTION

Owns job-done checks, idempotent approval/completion hashes, skip payloads,
and the default legal-hold reason. It does not write rows.
L<GPForum::Service::Privacy::DeletionWorkflow> still locks requests and
creates jobs. Event and audit hashes live in
L<GPForum::Service::Privacy::Event>.

=head1 SUBROUTINES/METHODS

=head2 job_done

True when an erasure job status is C<done>.

=head2 approval_replay

Returns the idempotent approved-job hash.

=head2 completion_replay

Returns the idempotent completed-job hash.

=head2 skipped

Returns a skipped-erasure hash for a named reason.

=head2 hold_reason

Returns a caller reason or C<active legal hold>.

=head1 DIAGNOSTICS

None. Persistence errors stay in the deletion workflow.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<GPForum::Service::Privacy::Record>, and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Hold blocking and credential revocation stay on the workflow.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
