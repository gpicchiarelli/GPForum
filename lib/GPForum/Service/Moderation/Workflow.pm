package GPForum::Service::Moderation::Workflow;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Base -base;

our $VERSION = '0.001';

has action_store        => undef;
has command_idempotency => undef;
has logger              => undef;
has report_store        => undef;
has suspension_store    => undef;

sub hide_post {
    my ( $self, $input ) = @_;

    return $self->_action_write(
        {
            command_type => 'moderation.hide_post',
            input        => $input,
            not_found    => 'post not found',
            request      => _action_request($input),
            run => sub { return $self->action_store->hide_post($input); },
        }
    );
}

sub restore_post {
    my ( $self, $input ) = @_;

    return $self->_action_write(
        {
            command_type => 'moderation.restore_post',
            input        => $input,
            not_found    => 'post not found',
            request      => _action_request($input),
            run          => sub {
                return $self->action_store->restore_post($input);
            },
        }
    );
}

sub lock_thread {
    my ( $self, $input ) = @_;

    return $self->_action_write(
        {
            command_type => 'moderation.lock_thread',
            input        => $input,
            not_found    => 'thread not found',
            request      => _action_request($input),
            run          => sub {
                return $self->action_store->lock_thread($input);
            },
        }
    );
}

sub unlock_thread {
    my ( $self, $input ) = @_;

    return $self->_action_write(
        {
            command_type => 'moderation.unlock_thread',
            input        => $input,
            not_found    => 'thread not found',
            request      => _action_request($input),
            run          => sub {
                return $self->action_store->unlock_thread($input);
            },
        }
    );
}

sub hide_thread {
    my ( $self, $input ) = @_;

    return $self->_action_write(
        {
            command_type => 'moderation.hide_thread',
            input        => $input,
            not_found    => 'thread not found',
            request      => _action_request($input),
            run          => sub {
                return $self->action_store->hide_thread($input);
            },
        }
    );
}

sub restore_thread {
    my ( $self, $input ) = @_;

    return $self->_action_write(
        {
            command_type => 'moderation.restore_thread',
            input        => $input,
            not_found    => 'thread not found',
            request      => _action_request($input),
            run          => sub {
                return $self->action_store->restore_thread($input);
            },
        }
    );
}

sub reverse_action {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_field( $input, 'command_id' );
    if ($invalid) {
        return $invalid;
    }

    $invalid = $self->_missing_field( $input, 'reason' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_queue_write(
        {
            command_type => 'moderation.reverse',
            input        => $input,
            kind         => 'reverse',
            not_found    => 'moderation action not found',
            request      => _reverse_request($input),
            run          => sub {
                return $self->action_store->reverse_action( $input->{action_id},
                    $input->{actor_user_id},
                    $input->{reason}, );
            },
        }
    );
}

sub assign_report {
    my ( $self, $input ) = @_;

    return $self->_queue_write(
        {
            command_type => 'moderation.assign',
            input        => $input,
            request      => _assign_request($input),
            run          => sub {
                return $self->report_store->assign_report( $input->{report_id},
                    $input->{actor_user_id} );
            },
        }
    );
}

sub release_report {
    my ( $self, $input ) = @_;

    return $self->_queue_write(
        {
            command_type => 'moderation.release',
            input        => $input,
            request      => _assign_request($input),
            run          => sub {
                return $self->report_store->release_report( $input->{report_id},
                    $input->{actor_user_id} );
            },
        }
    );
}

sub resolve_report {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_field( $input, 'resolution' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_queue_write(
        {
            command_type => 'moderation.resolve',
            input        => $input,
            request      => _resolve_request($input),
            run          => sub {
                return $self->report_store->resolve_report( $input->{report_id},
                    $input->{resolution}, $input->{actor_user_id},
                );
            },
        }
    );
}

sub _queue_write {
    my ( $self, $job ) = @_;

    my $invalid = $self->_missing_field( $job->{input}, 'command_id' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_idempotent_store(
        {
            actor_id     => $job->{input}{actor_user_id},
            command_id   => $job->{input}{command_id},
            command_type => $job->{command_type},
            kind         => $job->{kind}      || 'report',
            not_found    => $job->{not_found} || 'report not found',
            request      => $job->{request},
            run          => $job->{run},
        }
    );
}

sub suspend_user {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_field( $input, 'reason' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_suspend_commanded($input);
}

sub _suspend_commanded {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_field( $input, 'command_id' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_persist_suspend($input);
}

sub _persist_suspend {
    my ( $self, $input ) = @_;

    return $self->_idempotent_store(
        {
            actor_id     => $input->{actor_user_id},
            command_id   => $input->{command_id},
            command_type => 'moderation.suspend',
            kind         => 'suspend',
            not_found    => 'user not found',
            request      => _suspend_request($input),
            run          => sub {
                return $self->suspension_store->create_suspension($input);
            },
        }
    );
}

sub revoke_suspension {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_field( $input, 'reason' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_revoke_commanded($input);
}

sub _revoke_commanded {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_field( $input, 'command_id' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_persist_revoke($input);
}

sub _persist_revoke {
    my ( $self, $input ) = @_;

    return $self->_idempotent_store(
        {
            actor_id     => $input->{actor_user_id},
            command_id   => $input->{command_id},
            command_type => 'moderation.suspension_revoke',
            kind         => 'revoke',
            not_found    => 'suspension not found',
            request      => _revoke_request($input),
            run          => sub {
                return $self->suspension_store->revoke_suspension(
                    $input->{suspension_id},
                    $input->{actor_user_id},
                    $input->{reason},
                );
            },
        }
    );
}

sub _idempotent_store {
    my ( $self, $job ) = @_;

    return $self->_commanded_write(
        {
            actor_id     => $job->{actor_id},
            command_id   => $job->{command_id},
            command_type => $job->{command_type},
            request      => $job->{request} || {},
            run          => sub { return $self->_public_run($job); },
        }
    );
}

sub _public_run {
    my ( $self, $job ) = @_;

    my $result = $self->_run_store( $job->{not_found}, $job->{run} );
    if ( !$result->{ok} ) {
        return $result;
    }

    return _result(
        status => 'ok',
        stored => _public_stored( $job->{kind}, $result->{stored} ),
    );
}

sub _commanded_write {
    my ( $self, $job ) = @_;

    if ( !$self->command_idempotency ) {
        return $job->{run}->();
    }

    return $self->_idempotent_write($job);
}

sub _idempotent_write {
    my ( $self, $job ) = @_;

    my $guarded = eval { return $self->_command_guard($job); };
    if ($EVAL_ERROR) {
        $self->_log_error("moderation command log failed: $EVAL_ERROR");
        return _result(
            error  => 'moderation store failed',
            status => 'failed',
        );
    }

    return _guard_result($guarded);
}

sub _command_guard {
    my ( $self, $job ) = @_;

    return $self->command_idempotency->run(
        {
            actor_id     => $job->{actor_id},
            command_id   => _trim( $job->{command_id} ),
            command_type => $job->{command_type},
            request      => $job->{request} || {},
        },
        sub { return $job->{run}->(); },
        sub {
            my ($result) = @_;
            return $result;
        },
    );
}

sub _guard_result {
    my ($guarded) = @_;

    if ( $guarded->{replayed} ) {
        return $guarded->{response};
    }
    if ( $guarded->{recorded} ) {
        return $guarded->{result};
    }

    return _guard_failure($guarded);
}

sub _guard_failure {
    my ($guarded) = @_;

    if ( $guarded->{invalid} ) {
        return _result(
            errors => { command_id => 'command_id is required' },
            status => 'invalid',
        );
    }

    return _result(
        error  => $guarded->{error},
        status => 'conflict',
    );
}

sub _public_stored {
    my ( $kind, $stored ) = @_;

    if ( $kind eq 'suspend' ) {
        return _public_suspend($stored);
    }
    if ( $kind eq 'revoke' ) {
        return _public_revoke($stored);
    }

    return _public_queue_stored( $kind, $stored );
}

sub _public_queue_stored {
    my ( $kind, $stored ) = @_;

    if ( $kind eq 'reverse' ) {
        return _public_reverse($stored);
    }
    if ( $kind eq 'action' ) {
        return _public_action($stored);
    }

    return _public_report($stored);
}

sub _public_action {
    my ($stored) = @_;

    $stored ||= {};
    my $action = $stored->{action} || $stored;

    return {
        ok     => 1,
        action => {
            action_type          => $action->{action_type},
            actor_user_id        => $action->{actor_user_id},
            command_id           => $action->{command_id},
            created_at           => $action->{created_at},
            metadata             => $action->{metadata},
            moderation_action_id => $action->{moderation_action_id},
            reason               => $action->{reason},
            reversed_at          => $action->{reversed_at},
            reversed_by_user_id  => $action->{reversed_by_user_id},
            target_id            => $action->{target_id},
            target_type          => $action->{target_type},
        },
    };
}

sub _public_report {
    my ($stored) = @_;

    $stored ||= {};

    return {
        actor_user_id              => $stored->{actor_user_id},
        assigned_moderator_user_id => $stored->{assigned_moderator_user_id},
        report_id                  => $stored->{report_id},
        resolution                 => $stored->{resolution},
        resolved_at                => $stored->{resolved_at},
        status                     => $stored->{status},
    };
}

sub _public_reverse {
    my ($stored) = @_;

    $stored ||= {};
    my $action = $stored->{action} || $stored;

    return {
        moderation_action_id => $action->{moderation_action_id},
        reason               => $action->{reason},
        reversed_at          => $action->{reversed_at},
        reversed_by_user_id  => $action->{reversed_by_user_id},
    };
}

sub _public_suspend {
    my ($stored) = @_;

    $stored ||= {};
    my $suspension = $stored->{suspension} || $stored;

    return {
        ok         => 1,
        suspension => {
            actor_user_id => $suspension->{actor_user_id},
            reason        => $suspension->{reason},
            revoked_at    => $suspension->{revoked_at},
            suspension_id => $suspension->{suspension_id},
            user_id       => $suspension->{user_id},
            valid_from    => $suspension->{valid_from},
            valid_to      => $suspension->{valid_to},
        },
    };
}

sub _public_revoke {
    my ($stored) = @_;

    $stored ||= {};

    return {
        actor_user_id => $stored->{actor_user_id},
        reason        => $stored->{reason},
        revoked_at    => $stored->{revoked_at},
        suspension_id => $stored->{suspension_id},
    };
}

sub _suspend_request {
    my ($input) = @_;

    my $request = {
        actor_user_id => $input->{actor_user_id},
        reason        => _trim( $input->{reason} ),
        user_id       => $input->{user_id},
    };
    if ( defined $input->{valid_to} && length $input->{valid_to} ) {
        $request->{valid_to} = $input->{valid_to};
    }

    return $request;
}

sub _revoke_request {
    my ($input) = @_;

    return {
        actor_user_id => $input->{actor_user_id},
        reason        => _trim( $input->{reason} ),
        suspension_id => $input->{suspension_id},
    };
}

sub _assign_request {
    my ($input) = @_;

    return {
        actor_user_id => $input->{actor_user_id},
        report_id     => $input->{report_id},
    };
}

sub _resolve_request {
    my ($input) = @_;

    my $request = _assign_request($input);
    $request->{resolution} = _trim( $input->{resolution} );

    return $request;
}

sub _reverse_request {
    my ($input) = @_;

    return {
        action_id     => $input->{action_id},
        actor_user_id => $input->{actor_user_id},
        reason        => _trim( $input->{reason} ),
    };
}

sub _action_write {
    my ( $self, $job ) = @_;

    my $invalid = $self->_missing_field( $job->{input}, 'reason' );
    if ($invalid) {
        return $invalid;
    }

    return $self->_queue_write(
        {
            command_type => $job->{command_type},
            input        => $job->{input},
            kind         => 'action',
            not_found    => $job->{not_found},
            request      => $job->{request},
            run          => $job->{run},
        }
    );
}

sub _action_request {
    my ($input) = @_;

    my $request = {
        actor_user_id => $input->{actor_user_id},
        reason        => _trim( $input->{reason} ),
    };
    _copy_target( $request, $input, 'post_id' );
    _copy_target( $request, $input, 'thread_id' );

    return $request;
}

sub _copy_target {
    my ( $request, $input, $field ) = @_;

    if ( defined $input->{$field} && length $input->{$field} ) {
        $request->{$field} = $input->{$field};
    }

    return;
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

=head2 hide_thread

Hides a thread when a reason is present.

=head2 restore_thread

Restores a hidden thread when a reason is present.

=head2 reverse_action

Records reversal of a prior moderation action when a command id and reason
are present.

=head2 assign_report

Assigns an open report to the acting moderator when a command id is present.

=head2 release_report

Releases a report assignment when a command id is present.

=head2 resolve_report

Resolves a report when a command id and resolution are present.

=head2 suspend_user

Creates a user suspension when a command id and reason are present.

=head2 revoke_suspension

Revokes a suspension when a command id and reason are present.

=head1 DIAGNOSTICS

Returns C<invalid>, C<not_found>, or C<failed> statuses instead of throwing for
expected write outcomes. Unexpected store exceptions are logged and mapped to
C<failed>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses action, report, and suspension stores plus the command-idempotency
helper supplied by the composition root.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Command-id is required for assign, release, resolve, reverse, hide, restore,
lock, unlock, suspend, and revoke. Those writes replay from C<command_log>
when the helper is present. Hide, restore, lock, and unlock also keep
store-level unique C<command_id>. Reverse store arity stays four arguments.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
