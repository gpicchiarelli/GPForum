package GPForum::Web::ModerationAccess;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_QUEUE_LIMIT       => 50;
const my $WRITE_RATE_LIMIT          => 20;
const my $WRITE_RATE_WINDOW         => 60;
const my $WRITE_ACTION              => 'moderation.write';
const my $REPORT_RESOURCE           => 'report';
const my $MODERATION_RESOURCE       => 'moderation_action';
const my $SUSPENSION_RESOURCE       => 'suspension';
const my $POST_RESOURCE             => 'post';
const my $THREAD_RESOURCE           => 'thread';
const my $USER_RESOURCE             => 'user';
const my $ACTION_VIEW               => 'view';
const my $ACTION_VIEW_QUEUE         => 'view_queue';
const my $ACTION_MODERATE           => 'moderate';
const my $ACTION_REVERSE            => 'reverse';
const my $ACTION_ASSIGN             => 'assign';
const my $ACTION_RESOLVE            => 'resolve';
const my $ACTION_SUSPEND            => 'suspend';
const my $STATUS_POST_HIDDEN        => 'post_hidden';
const my $STATUS_POST_RESTORED      => 'post_restored';
const my $STATUS_THREAD_LOCKED      => 'thread_locked';
const my $STATUS_THREAD_UNLOCKED    => 'thread_unlocked';
const my $STATUS_ACTION_REVERSED    => 'action_reversed';
const my $STATUS_ASSIGNED           => 'assigned';
const my $STATUS_RELEASED           => 'released';
const my $STATUS_RESOLVED           => 'resolved';
const my $STATUS_USER_SUSPENDED     => 'user_suspended';
const my $STATUS_SUSPENSION_REVOKED => 'suspension_revoked';
const my $QUEUE_STATUS_OPEN         => 'open';
const my $SUSPENSION_STATUS_ACTIVE  => 'active';
const my $SUSPENSION_STATUS_ALL     => 'all';
const my $STATUS_FAILED             => 'failed';
const my $STATUS_NOT_FOUND          => 'not_found';
const my $STATUS_INVALID            => 'invalid';

sub queue_limit {
    my ( undef, $requested ) = @_;

    return $requested || $DEFAULT_QUEUE_LIMIT;
}

sub queue_status {
    my ( undef, $status ) = @_;

    if ( defined $status && length $status ) {
        return $status;
    }

    return $QUEUE_STATUS_OPEN;
}

sub suspension_status {
    my ( undef, $status ) = @_;

    if ( defined $status && $status eq $SUSPENSION_STATUS_ALL ) {
        return $SUSPENSION_STATUS_ALL;
    }

    return $SUSPENSION_STATUS_ACTIVE;
}

sub write_action {
    return $WRITE_ACTION;
}

sub write_rate_input {
    my ( undef, $input ) = @_;

    return {
        action         => $input->{action},
        actor_id       => $input->{actor_id},
        limit          => $WRITE_RATE_LIMIT,
        scope          => 'moderation_http',
        window_seconds => $WRITE_RATE_WINDOW,
    };
}

sub view_action {
    return $ACTION_VIEW;
}

sub view_queue_action {
    return $ACTION_VIEW_QUEUE;
}

sub moderate_action {
    return $ACTION_MODERATE;
}

sub reverse_action {
    return $ACTION_REVERSE;
}

sub assign_action {
    return $ACTION_ASSIGN;
}

sub resolve_action {
    return $ACTION_RESOLVE;
}

sub suspend_action {
    return $ACTION_SUSPEND;
}

sub moderation_resource {
    return $MODERATION_RESOURCE;
}

sub suspension_resource {
    return $SUSPENSION_RESOURCE;
}

sub post_resource {
    return $POST_RESOURCE;
}

sub thread_resource {
    return $THREAD_RESOURCE;
}

sub user_resource {
    return $USER_RESOURCE;
}

sub post_hidden_status {
    return $STATUS_POST_HIDDEN;
}

sub post_restored_status {
    return $STATUS_POST_RESTORED;
}

sub thread_locked_status {
    return $STATUS_THREAD_LOCKED;
}

sub thread_unlocked_status {
    return $STATUS_THREAD_UNLOCKED;
}

sub action_reversed_status {
    return $STATUS_ACTION_REVERSED;
}

sub assigned_status {
    return $STATUS_ASSIGNED;
}

sub released_status {
    return $STATUS_RELEASED;
}

sub resolved_status {
    return $STATUS_RESOLVED;
}

sub user_suspended_status {
    return $STATUS_USER_SUSPENDED;
}

sub suspension_revoked_status {
    return $STATUS_SUSPENSION_REVOKED;
}

sub authorization_target {
    my ( undef, $resource_type, $action ) = @_;

    if ( !defined $action ) {
        return {
            action        => $resource_type,
            resource_type => $REPORT_RESOURCE,
        };
    }

    return {
        action        => $action,
        resource_type => $resource_type,
    };
}

sub is_failed {
    my ( $self, $result ) = @_;

    return $self->_status($result) eq $STATUS_FAILED ? 1 : 0;
}

sub failure_status {
    my ( $self, $result ) = @_;

    my $status = $self->_status($result);
    if ( $status eq $STATUS_NOT_FOUND ) {
        return $status;
    }
    if ( $status eq $STATUS_INVALID ) {
        return $status;
    }

    return;
}

sub invalid_request {
    my ( undef, $errors ) = @_;

    return {
        error  => 'The submitted moderation request was invalid.',
        errors => $errors,
        title  => 'Invalid moderation request',
    };
}

sub _status {
    my ( undef, $result ) = @_;

    return $result->{status} || q{};
}

1;

__END__

=head1 NAME

GPForum::Web::ModerationAccess - Moderation queue limits and HTTP policy.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $limit = $access->queue_limit($requested);

=head1 DESCRIPTION

Owns report-queue page limits, default queue and suspension filters,
the C<moderation_http> write rate-limit hash, permission action and resource
names, write-success statuses, permission-target hashes, workflow
failure-status mapping, and the Guard payload for invalid moderation
requests. It does not render HTTP responses or load reports.
L<GPForum::Controller::Moderation::Base> still checks CSRF, sessions,
permissions, the rate limiter, and Guard errors.

=head1 SUBROUTINES/METHODS

=head2 write_action

Returns C<moderation.write>.

=head2 write_rate_input

Returns the C<moderation_http> rate-limit arguments.

=head2 queue_limit

Returns a requested queue size or the default of 50.

=head2 queue_status

Returns a requested report status or C<open>.

=head2 suspension_status

Returns C<all> when requested, otherwise C<active>.

=head2 view_action

Returns C<view>.

=head2 view_queue_action

Returns C<view_queue>.

=head2 moderate_action

Returns C<moderate>.

=head2 reverse_action

Returns C<reverse>.

=head2 assign_action

Returns C<assign>.

=head2 resolve_action

Returns C<resolve>.

=head2 suspend_action

Returns C<suspend>.

=head2 moderation_resource

Returns C<moderation_action>.

=head2 suspension_resource

Returns C<suspension>.

=head2 post_resource

Returns C<post>.

=head2 thread_resource

Returns C<thread>.

=head2 user_resource

Returns C<user>.

=head2 post_hidden_status

Returns C<post_hidden>.

=head2 post_restored_status

Returns C<post_restored>.

=head2 thread_locked_status

Returns C<thread_locked>.

=head2 thread_unlocked_status

Returns C<thread_unlocked>.

=head2 action_reversed_status

Returns C<action_reversed>.

=head2 assigned_status

Returns C<assigned>.

=head2 released_status

Returns C<released>.

=head2 resolved_status

Returns C<resolved>.

=head2 user_suspended_status

Returns C<user_suspended>.

=head2 suspension_revoked_status

Returns C<suspension_revoked>.

=head2 authorization_target

Returns the permission resource/action hash, defaulting the resource to
C<report> when only an action is supplied.

=head2 is_failed

True when the workflow status is C<failed>.

=head2 failure_status

Returns C<not_found> or C<invalid> when those statuses are present.

=head2 invalid_request

Returns the Guard bad-request payload for an invalid moderation command.

=head1 DIAGNOSTICS

None. HTTP rendering stays on the moderation controllers.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

CSRF, authentication, permission checks, rate-limiter calls, telemetry,
and Guard rendering remain on L<GPForum::Controller::Moderation::Base>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
