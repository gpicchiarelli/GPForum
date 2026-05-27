package GPForum::ViewModel::Moderation::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base';

our $VERSION = '0.001';

sub reports_page {
    my ( $self, %input ) = @_;

    return {
        csrf_token => $input{csrf_token},
        reports    => [ map { $self->report($_) } @{ $input{reports} || [] } ],
        status     => $input{status},
    };
}

sub actions_page {
    my ( $self, %input ) = @_;

    my $page = $input{page} || {};

    return {
        actions =>
          [ map { $self->moderation_action($_) } @{ $page->{items} || [] } ],
        csrf_token  => $input{csrf_token},
        next_cursor => $page->{next_cursor},
        target_id   => $input{target_id},
        target_type => $input{target_type},
    };
}

sub suspensions_page {
    my ( $self, %input ) = @_;

    my $page = $input{page} || {};

    return {
        csrf_token  => $input{csrf_token},
        next_cursor => $page->{next_cursor},
        status      => $input{status},
        suspensions =>
          [ map { $self->suspension($_) } @{ $page->{items} || [] } ],
        user_id => $input{user_id},
    };
}

sub suspension {
    my ( $self, $result ) = @_;

    my $suspension = $self->unwrap( $result, 'suspension' );

    return {
        actor_user_id => $self->column( $suspension, 'actor_user_id' ),
        metadata      => $self->column( $suspension, 'metadata' ),
        reason        => $self->column( $suspension, 'reason' ),
        revoked_at    => $self->column( $suspension, 'revoked_at' ),
        suspension_id => $self->column( $suspension, 'suspension_id' ),
        ui            => {
            heading_id => $self->stable_id(
                'suspension', $self->column( $suspension, 'suspension_id' ),
                'heading'
            ),
            revoke_reason_id => $self->stable_id(
                'suspension', $self->column( $suspension, 'suspension_id' ),
                'revoke-reason'
            ),
        },
        user_id    => $self->column( $suspension, 'user_id' ),
        valid_from => $self->column( $suspension, 'valid_from' ),
        valid_to   => $self->column( $suspension, 'valid_to' ),
    };
}

sub moderation_action {
    my ( $self, $result ) = @_;

    my $action = $self->unwrap( $result, 'action' );

    return {
        action_type          => $self->column( $action, 'action_type' ),
        actor_user_id        => $self->column( $action, 'actor_user_id' ),
        created_at           => $self->column( $action, 'created_at' ),
        metadata             => $self->column( $action, 'metadata' ),
        moderation_action_id =>
          $self->column( $action, 'moderation_action_id' ),
        reason              => $self->column( $action, 'reason' ),
        reversed_at         => $self->column( $action, 'reversed_at' ),
        reversed_by_user_id => $self->column( $action, 'reversed_by_user_id' ),
        target_id           => $self->column( $action, 'target_id' ),
        target_type         => $self->column( $action, 'target_type' ),
        ui                  => {
            heading_id => $self->stable_id(
                'action', $self->column( $action, 'moderation_action_id' ),
                'heading'
            ),
            restore_reason_id => $self->stable_id(
                'action', $self->column( $action, 'moderation_action_id' ),
                'restore-reason'
            ),
            reverse_heading_id => $self->stable_id(
                'action', $self->column( $action, 'moderation_action_id' ),
                'reverse-heading'
            ),
            reverse_reason_id => $self->stable_id(
                'action', $self->column( $action, 'moderation_action_id' ),
                'reverse-reason'
            ),
            reversible       => $self->column( $action, 'reversed_at' ) ? 0 : 1,
            unlock_reason_id => $self->stable_id(
                'action', $self->column( $action, 'moderation_action_id' ),
                'unlock-reason'
            ),
        },
    };
}

sub report {
    my ( $self, $row ) = @_;

    my $report_id = $self->column( $row, 'report_id' );

    return {
        assigned_moderator_user_id =>
          $self->column( $row, 'assigned_moderator_user_id' ),
        created_at       => $self->column( $row, 'created_at' ),
        details          => $self->column( $row, 'details' ),
        reason           => $self->column( $row, 'reason' ),
        report_id        => $report_id,
        reporter_user_id => $self->column( $row, 'reporter_user_id' ),
        resolution       => $self->column( $row, 'resolution' ),
        resolved_at      => $self->column( $row, 'resolved_at' ),
        status           => $self->column( $row, 'status' ),
        target_id        => $self->column( $row, 'target_id' ),
        target_type      => $self->column( $row, 'target_type' ),
        ui               => {
            heading_id => $self->stable_id( 'report', $report_id, 'heading' ),
            post_reason_id =>
              $self->stable_id( 'report', $report_id, 'post-reason' ),
            resolution_id =>
              $self->stable_id( 'report', $report_id, 'resolution' ),
            thread_reason_id =>
              $self->stable_id( 'report', $report_id, 'thread-reason' ),
            user_reason_id =>
              $self->stable_id( 'report', $report_id, 'user-reason' ),
            valid_to_id => $self->stable_id( 'report', $report_id, 'valid-to' ),
        },
    };
}

1;
