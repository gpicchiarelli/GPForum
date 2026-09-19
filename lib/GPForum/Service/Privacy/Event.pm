package GPForum::Service::Privacy::Event;

use strict;
use warnings;

use Const::Fast;
use GPForum::Service::Privacy::Record;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $SCHEMA_VERSION  => 1;
const my $REQUESTED       => 'privacy.deletion_requested';
const my $APPROVED        => 'privacy.deletion_approved';
const my $BLOCKED         => 'privacy.erasure_blocked';
const my $COMPLETED       => 'privacy.erasure_completed';
const my $HELD            => 'privacy.deletion_held';
const my $BLOCK_ERROR     => 'retention hold active';
const my $APPROVED_SUFFIX => ':approved';
const my $BLOCKED_SUFFIX  => ':blocked';
const my $DONE_SUFFIX     => ':done';
const my $HELD_SUFFIX     => ':held';
const my $HOLD_CREATED    => 'privacy.retention_hold_created';

has record => sub { return GPForum::Service::Privacy::Record->new; };

sub block_error {
    return $BLOCK_ERROR;
}

sub requested {
    my ( $self, $input ) = @_;

    my $request = $input->{request};

    return {
        action      => $REQUESTED,
        actor_id    => $input->{actor_id},
        created_at  => $self->record->column( $request, 'created_at' ),
        idempotency => $self->record->column( $request, 'deletion_request_id' ),
        metadata => { reason => $self->record->column( $request, 'reason' ) },
        payload  => $self->record->request_payload($request),
        request  => $request,
    };
}

sub approved {
    my ( $self, $input ) = @_;

    return {
        action      => $APPROVED,
        actor_id    => $input->{actor_id},
        created_at  => $input->{timestamp},
        idempotency => $input->{request_id} . $APPROVED_SUFFIX,
        metadata    => {
            deletion_action_id =>
              $self->record->column( $input->{action}, 'deletion_action_id' ),
            reason => $input->{reason} || q{},
        },
        payload => $self->_payload_with(
            $input->{request},
            { erasure_job_id => $self->_job_id( $input->{job} ) }
        ),
        request => $input->{request},
    };
}

sub blocked {
    my ( $self, $input ) = @_;

    return {
        action      => $BLOCKED,
        actor_id    => $input->{actor_id},
        created_at  => $input->{timestamp},
        idempotency => $input->{erasure_job_id} . $BLOCKED_SUFFIX,
        metadata    => {
            deletion_action_id =>
              $self->record->column( $input->{action}, 'deletion_action_id' ),
            reason => $BLOCK_ERROR,
        },
        payload => $self->_payload_with(
            $input->{request}, { erasure_job_id => $input->{erasure_job_id} }
        ),
        request => $input->{request},
    };
}

sub completed {
    my ( $self, $input ) = @_;

    return {
        action      => $COMPLETED,
        actor_id    => $input->{actor_id},
        created_at  => $input->{timestamp},
        idempotency => $input->{erasure_job_id} . $DONE_SUFFIX,
        metadata    => {
            deletion_action_id =>
              $self->record->column( $input->{action}, 'deletion_action_id' ),
        },
        payload => $self->_payload_with(
            $input->{request},
            {
                anonymized     => $input->{anonymized},
                erasure_job_id => $input->{erasure_job_id},
            }
        ),
        request => $input->{request},
    };
}

sub held {
    my ( $self, $input ) = @_;

    my $request    = $input->{request};
    my $request_id = $self->record->column( $request, 'deletion_request_id' );

    return {
        action      => $HELD,
        actor_id    => $input->{actor_id},
        created_at  => $input->{timestamp},
        idempotency => $request_id . $HELD_SUFFIX,
        metadata    => { reason => $input->{reason} },
        payload     => $self->record->request_payload($request),
        request     => $request,
    };
}

sub envelope {
    my ( $self, $input, $correlation_id ) = @_;

    my $request = $input->{request};

    return {
        actor_id          => $input->{actor_id},
        aggregate_id      => $self->record->column( $request, 'resource_id' ),
        aggregate_type    => $self->record->column( $request, 'resource_type' ),
        aggregate_version => $SCHEMA_VERSION,
        causation_id      => undef,
        correlation_id    => $correlation_id,
        event_type        => $input->{action},
        idempotency_key   =>
          join( q{:}, $input->{action}, $input->{idempotency} ),
        payload   => $input->{payload} || {},
        timestamp => $input->{created_at},
    };
}

sub audit {
    my ( $self, $input, $correlation_id ) = @_;

    my $request = $input->{request};

    return {
        action         => $input->{action},
        actor_id       => $input->{actor_id},
        correlation_id => $correlation_id,
        created_at     => $input->{created_at},
        metadata       => {
            deletion_request_id =>
              $self->record->column( $request, 'deletion_request_id' ),
            %{ $input->{metadata} || {} },
        },
        previous_hash  => undef,
        record_hash    => q{},
        schema_version => $SCHEMA_VERSION,
        target_id      => $self->record->column( $request, 'resource_id' ),
        target_type    => $self->record->column( $request, 'resource_type' ),
    };
}

sub hold_payload {
    my ( $self, $hold ) = @_;

    return {
        ends_at           => $self->record->column( $hold, 'ends_at' ),
        reason            => $self->record->column( $hold, 'reason' ),
        resource_id       => $self->record->column( $hold, 'resource_id' ),
        resource_type     => $self->record->column( $hold, 'resource_type' ),
        retention_hold_id =>
          $self->record->column( $hold, 'retention_hold_id' ),
        starts_at => $self->record->column( $hold, 'starts_at' ),
    };
}

sub hold_envelope {
    my ( $self, $input ) = @_;

    my $hold = $input->{hold};

    return {
        actor_id          => $input->{actor_id},
        aggregate_id      => $self->record->column( $hold, 'resource_id' ),
        aggregate_type    => $self->record->column( $hold, 'resource_type' ),
        aggregate_version => $SCHEMA_VERSION,
        causation_id      => undef,
        correlation_id    => $input->{correlation_id},
        event_type        => $HOLD_CREATED,
        idempotency_key   => join( q{:},
            $HOLD_CREATED,
            $self->record->column( $hold, 'retention_hold_id' ) ),
        payload   => $self->hold_payload($hold),
        timestamp => $self->record->column( $hold, 'created_at' ),
    };
}

sub hold_audit {
    my ( $self, $input ) = @_;

    my $hold = $input->{hold};

    return {
        action         => $HOLD_CREATED,
        actor_id       => $input->{actor_id},
        correlation_id => $input->{correlation_id},
        created_at     => $self->record->column( $hold, 'created_at' ),
        metadata       => {
            reason            => $self->record->column( $hold, 'reason' ),
            retention_hold_id =>
              $self->record->column( $hold, 'retention_hold_id' ),
        },
        previous_hash  => undef,
        record_hash    => q{},
        schema_version => $SCHEMA_VERSION,
        target_id      => $self->record->column( $hold, 'resource_id' ),
        target_type    => $self->record->column( $hold, 'resource_type' ),
    };
}

sub _payload_with {
    my ( $self, $request, $extra ) = @_;

    return { %{ $self->record->request_payload($request) }, %{$extra}, };
}

sub _job_id {
    my ( $self, $job ) = @_;

    return $self->record->column( $job, 'erasure_job_id' );
}

1;

__END__

=head1 NAME

GPForum::Service::Privacy::Event - Privacy event and audit hashes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $event = $events->approved(
        {
            action     => $action,
            actor_id   => $actor_id,
            job        => $job,
            request    => $request,
            request_id => $request_id,
            timestamp  => $timestamp,
        }
    );

=head1 DESCRIPTION

Owns deletion-request, approval, hold, block, completion, and retention-hold
EventLog input hashes plus the recorder EventLog and AuditLog argument
hashes. It does not persist rows.
L<GPForum::Service::Privacy::DeletionWorkflow> and
L<GPForum::Service::Privacy::RetentionHoldStore> still write EventLog,
OutboxMessage, and AuditLog.

=head1 SUBROUTINES/METHODS

=head2 block_error

Returns the retention-hold last_error text.

=head2 requested

Returns the deletion-requested event hash.

=head2 approved

Returns the deletion-approved event hash.

=head2 blocked

Returns the erasure-blocked event hash.

=head2 completed

Returns the erasure-completed event hash.

=head2 held

Returns the deletion-held event hash.

=head2 envelope

Returns EventLog arguments for the recorder.

=head2 audit

Returns AuditLog arguments for the recorder.

=head2 hold_payload

Returns the retention-hold EventLog payload.

=head2 hold_envelope

Returns EventLog arguments for a created retention hold.

=head2 hold_audit

Returns AuditLog arguments for a created retention hold.

=head1 DIAGNOSTICS

None. Persistence errors stay in the stores.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<GPForum::Service::Privacy::Record>, and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

C<FOR UPDATE> locks, ErasureJob writes, and retention-hold row inserts stay
on the stores.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
