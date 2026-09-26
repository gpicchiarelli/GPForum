# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PrivacyWebServices;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has created_deletion_requests => sub { return []; };
has created_export_requests   => sub { return []; };
has created_holds             => sub { return []; };

sub deletion_requests_for_user {
    my ( $self, $user_id ) = @_;

    return [
        {
            completed_at        => undef,
            created_at          => '2026-05-23T12:00:00Z',
            deletion_request_id => 'delete-own-1',
            reason              => 'account cleanup',
            request_type        => 'anonymize',
            requester_user_id   => $user_id,
            resource_id         => $user_id,
            resource_type       => 'user',
            status              => 'pending',
        },
        @{ $self->created_deletion_requests },
    ];
}

sub export_requests_for_user {
    my ( $self, $user_id ) = @_;

    return [
        {
            created_at        => '2026-05-23T12:00:00Z',
            export_request_id => 'export-own-1',
            export_type       => 'user_data',
            finished_at       => '2026-05-23T12:00:00Z',
            format            => 'json',
            manifest          => _manifest(),
            requester_user_id => $user_id,
            status            => 'completed',
            subject_user_id   => $user_id,
        },
        @{ $self->created_export_requests },
    ];
}

sub completed_export_for_user {
    my ( $self, $user_id, $export_request_id ) = @_;

    my $match = $self->_export_row( $user_id, $export_request_id );
    if ( !$match ) {
        return;
    }
    if ( !_completed_export($match) ) {
        return;
    }

    return $match;
}

sub _export_row {
    my ( $self, $user_id, $export_request_id ) = @_;

    if ( !_has_export_id($export_request_id) ) {
        return;
    }

    my ($match) =
      grep { $_->{export_request_id} eq $export_request_id }
      @{ $self->export_requests_for_user($user_id) };

    return $match;
}

sub _has_export_id {
    my ($export_request_id) = @_;

    if ( !$export_request_id ) {
        return 0;
    }
    if ( $export_request_id eq 'missing' ) {
        return 0;
    }

    return 1;
}

sub _completed_export {
    my ($match) = @_;

    if ( _export_status($match) eq 'completed' ) {
        return 1;
    }

    return 0;
}

sub _export_status {
    my ($match) = @_;

    if ( defined $match->{status} ) {
        return $match->{status};
    }

    return q{};
}

sub active_holds_for_user {
    my ( $self, $user_id ) = @_;

    return [
        grep { $_->{resource_type} eq 'user' && $_->{resource_id} eq $user_id }
          @{ $self->created_holds } ];
}

sub pending_deletion_requests {
    return [
        {
            completed_at        => undef,
            created_at          => '2026-05-23T12:00:00Z',
            deletion_request_id => 'delete-1',
            reason              => 'leaving service',
            request_type        => 'anonymize',
            requester_user_id   => 'user-1',
            resource_id         => 'user-1',
            resource_type       => 'user',
            status              => 'pending',
        },
    ];
}

sub pending_export_requests {
    return [
        {
            created_at        => '2026-05-23T12:00:00Z',
            export_request_id => 'export-review-1',
            export_type       => 'user_data',
            finished_at       => undef,
            format            => 'json',
            manifest          => {},
            requester_user_id => 'user-1',
            status            => 'pending',
            subject_user_id   => 'user-1',
        },
    ];
}

sub active_holds {
    my ($self) = @_;

    return $self->created_holds;
}

sub erasure_jobs_by_status {
    my ( $self, $status ) = @_;

    return [] if $status ne 'pending';

    return [
        {
            completed_at        => undef,
            deletion_request_id => 'delete-1',
            erasure_job_id      => 'job-1',
            last_error          => undef,
            scheduled_at        => '2026-05-23T12:00:00Z',
            status              => 'pending',
        },
        {
            completed_at        => undef,
            deletion_request_id => 'delete-held',
            erasure_job_id      => 'job-held',
            last_error          => 'retention hold active',
            scheduled_at        => '2026-05-23T12:00:00Z',
            status              => 'pending',
        },
    ];
}

sub deletion_request {
    my ( $self, $request_id ) = @_;

    return if $request_id eq 'missing';

    return {
        completed_at        => undef,
        created_at          => '2026-05-23T12:00:00Z',
        deletion_request_id => $request_id,
        reason              => 'leaving service',
        request_type        => 'anonymize',
        requester_user_id   => 'user-1',
        resource_id         => 'user-1',
        resource_type       => 'user',
        status              => 'pending',
    };
}

sub request_user_export {
    my ( $self, $user_id ) = @_;

    my $request = {
        created_at        => '2026-05-23T12:00:00Z',
        export_request_id => 'export-created',
        export_type       => 'user_data',
        finished_at       => undef,
        format            => 'json',
        manifest          => {},
        requester_user_id => $user_id,
        status            => 'pending',
        subject_user_id   => $user_id,
    };
    push @{ $self->created_export_requests }, $request;

    return $request;
}

sub complete_user_export {
    my ( $self, $export_request_id ) = @_;

    my $completed = {
        created_at        => '2026-05-23T12:00:00Z',
        export_request_id => $export_request_id,
        export_type       => 'user_data',
        finished_at       => '2026-05-23T12:00:00Z',
        format            => 'json',
        manifest          => _manifest(),
        requester_user_id => 'user-1',
        status            => 'completed',
        subject_user_id   => 'user-1',
    };
    push @{ $self->created_export_requests }, $completed;

    return $completed;
}

sub request_deletion {
    my ( $self, $input ) = @_;

    my $request = {
        completed_at        => undef,
        created_at          => '2026-05-23T12:00:00Z',
        deletion_request_id => 'delete-created',
        reason              => $input->{reason},
        request_type        => $input->{request_type},
        requester_user_id   => $input->{requester_user_id},
        resource_id         => $input->{resource_id},
        resource_type       => $input->{resource_type},
        status              => 'pending',
    };
    push @{ $self->created_deletion_requests }, $request;

    return $request;
}

sub approve_request {
    my ( $self, $request_id, $actor_id, $reason ) = @_;

    return if $request_id eq 'missing';

    return {
        action => {
            actor_id           => $actor_id,
            action_type        => 'released',
            deletion_action_id => 'action-approved',
            metadata           => { reason => $reason },
        },
        job => {
            deletion_request_id => $request_id,
            erasure_job_id      => 'job-approved',
            status              => 'pending',
        },
        ok         => 1,
        request_id => $request_id,
    };
}

sub create_hold {
    my ( $self, $input ) = @_;

    my $hold = {
        created_at        => '2026-05-23T12:00:00Z',
        created_by        => $input->{created_by},
        ends_at           => undef,
        reason            => $input->{reason},
        resource_id       => $input->{resource_id},
        resource_type     => $input->{resource_type},
        retention_hold_id => 'hold-created',
        starts_at         => '2026-05-23T12:00:00Z',
    };
    push @{ $self->created_holds }, $hold;

    return $hold;
}

sub hold_request {
    my ( $self, $request_id, $actor_id, $reason, $hold ) = @_;

    return {
        action => {
            actor_id           => $actor_id,
            action_type        => 'held',
            deletion_action_id => 'action-held',
            metadata           => {
                reason            => $reason,
                retention_hold_id => $hold->{retention_hold_id},
            },
        },
        ok         => 1,
        request_id => $request_id,
    };
}

sub complete_job {
    my ( $self, $job_id, $actor_id ) = @_;

    return if $job_id eq 'missing';
    return {
        error          => 'retention_hold_active',
        erasure_job_id => $job_id,
        ok             => 0,
      }
      if $job_id eq 'job-held';

    return {
        action => {
            actor_id           => $actor_id,
            action_type        => 'anonymized',
            deletion_action_id => 'action-erased',
        },
        erasure_job_id => $job_id,
        ok             => 1,
    };
}

sub _manifest {
    return {
        counts => {
            attachments   => 0,
            notifications => 1,
            posts         => 2,
            preferences   => 1,
            subscriptions => 1,
        },
        format       => 'json',
        generated_at => '2026-05-23T12:00:00Z',
        posts        => [ { body_source => 'Hello', post_id => 'post-1' } ],
        profile => { email => 'giacomo@example.test', username => 'giacomo' },
        subject_user_id => 'user-1',
    };
}

1;
