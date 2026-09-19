package GPForum::Service::Moderation::Workflow;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Base -base;

our $VERSION = '0.001';

has action_store     => undef;
has logger           => undef;
has report_store     => undef;
has suspension_store => undef;

sub hide_post {
    my ( $self, $input ) = @_;

    return $self->_reasoned_write(
        $input,
        'post not found',
        sub { return $self->action_store->hide_post($input); },
    );
}

sub restore_post {
    my ( $self, $input ) = @_;

    return $self->_reasoned_write(
        $input,
        'post not found',
        sub { return $self->action_store->restore_post($input); },
    );
}

sub lock_thread {
    my ( $self, $input ) = @_;

    return $self->_reasoned_write(
        $input,
        'thread not found',
        sub { return $self->action_store->lock_thread($input); },
    );
}

sub unlock_thread {
    my ( $self, $input ) = @_;

    return $self->_reasoned_write(
        $input,
        'thread not found',
        sub { return $self->action_store->unlock_thread($input); },
    );
}

sub reverse_action {
    my ( $self, $input ) = @_;

    return $self->_reasoned_write(
        $input,
        'moderation action not found',
        sub {
            return $self->action_store->reverse_action( $input->{action_id},
                $input->{actor_user_id},
                $input->{reason}, );
        },
    );
}

sub assign_report {
    my ( $self, $input ) = @_;

    return $self->_run_store(
        'report not found',
        sub {
            return $self->report_store->assign_report( $input->{report_id},
                $input->{actor_user_id} );
        },
    );
}

sub release_report {
    my ( $self, $input ) = @_;

    return $self->_run_store(
        'report not found',
        sub {
            return $self->report_store->release_report( $input->{report_id},
                $input->{actor_user_id} );
        },
    );
}

sub resolve_report {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_field( $input, 'resolution' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_run_store(
        'report not found',
        sub {
            return $self->report_store->resolve_report( $input->{report_id},
                $input->{resolution}, $input->{actor_user_id},
            );
        },
    );
}

sub suspend_user {
    my ( $self, $input ) = @_;

    return $self->_reasoned_write(
        $input,
        'user not found',
        sub { return $self->suspension_store->create_suspension($input); },
    );
}

sub revoke_suspension {
    my ( $self, $input ) = @_;

    return $self->_reasoned_write(
        $input,
        'suspension not found',
        sub {
            return $self->suspension_store->revoke_suspension(
                $input->{suspension_id},
                $input->{actor_user_id},
                $input->{reason},
            );
        },
    );
}

sub _reasoned_write {
    my ( $self, $input, $not_found, $code ) = @_;

    my $invalid = $self->_missing_field( $input, 'reason' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_run_store( $not_found, $code );
}

sub _missing_field {
    my ( undef, $input, $field ) = @_;

    if ( !length _trim( $input->{$field} ) ) {
        return _result(
            status => 'invalid',
            errors => { $field => "$field is required" },
        );
    }

    return;
}

sub _run_store {
    my ( $self, $not_found, $code ) = @_;

    my $stored = $self->_eval_store($code);
    if ( $stored->{failed} ) {
        return _result(
            status => 'failed',
            error  => 'moderation store failed',
        );
    }
    if ( !$stored->{value} ) {
        return _result(
            status => 'not_found',
            error  => $not_found,
        );
    }

    return _result(
        status => 'ok',
        stored => $stored->{value},
    );
}

sub _eval_store {
    my ( $self, $code ) = @_;

    my $value = eval { return $code->(); };
    if ($EVAL_ERROR) {
        $self->_log_error("moderation write failed: $EVAL_ERROR");
        return { failed => 1 };
    }

    return { value => $value };
}

sub _result {
    my (%input) = @_;

    return {
        error  => $input{error},
        errors => $input{errors},
        ok     => ( $input{status} || q{} ) eq 'ok' ? 1 : 0,
        status => $input{status} || 'failed',
        stored => $input{stored},
    };
}

sub _trim {
    my ($value) = @_;

    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _log_error {
    my ( $self, $message ) = @_;

    if ( !$self->logger || !$self->logger->can('error') ) {
        return;
    }

    $self->logger->error($message);

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Moderation::Workflow - Moderation write commands.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = $workflow->hide_post(
        {
            actor_user_id => $user_id,
            post_id       => $post_id,
            reason        => $reason,
        }
    );

=head1 DESCRIPTION

Application boundary for moderation writes. Validates required command fields,
delegates persistence to report, action, and suspension stores, and returns a
normalized result hash. Stores keep transaction, event, audit, and outbox
ownership.

=head1 SUBROUTINES/METHODS

=head2 hide_post

Hides a post when a reason is present.

=head2 restore_post

Restores a hidden post when a reason is present.

=head2 lock_thread

Locks a thread when a reason is present.

=head2 unlock_thread

Unlocks a thread when a reason is present.

=head2 reverse_action

Records reversal of a prior moderation action.

=head2 assign_report

Assigns an open report to the acting moderator.

=head2 release_report

Releases a report assignment.

=head2 resolve_report

Resolves a report when a resolution is present.

=head2 suspend_user

Creates a user suspension when a reason is present.

=head2 revoke_suspension

Revokes a suspension when a reason is present.

=head1 DIAGNOSTICS

Returns C<invalid>, C<not_found>, or C<failed> statuses instead of throwing for
expected write outcomes. Unexpected store exceptions are logged and mapped to
C<failed>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses action, report, and suspension stores supplied by the composition root.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Command-id replay is not required; stores keep their existing state-based
idempotency.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
