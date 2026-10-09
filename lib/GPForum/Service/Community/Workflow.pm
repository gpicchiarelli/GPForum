# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Community::Workflow;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

const my $REPORT_DETAILS_MAX => 2_000;
const my $REPORT_REASON_MAX  => 80;
const my %PUBLIC_FIELDS => (
    bookmark => [
        qw(bookmark_id created_at deleted_at note ok target_id target_type user_id)
    ],
    report => [
        qw(created_at details reason report_id reporter_user_id status target_id
          target_type)
    ],
    subscription => [
        qw(created_at muted_at ok preference revoked_at subscription_id target_id
          target_type user_id)
    ],
);

__PACKAGE__->requires(qw(bookmark_store report_store subscription_store));
has command_idempotency => undef;    # optional: writes run unlogged without one
has logger              => undef;    # optional: errors are dropped without one

sub save_bookmark ( $self, $input ) {
    return $self->_commanded_op(
        {
            command_type => 'community.bookmark',
            input        => $input,
            kind         => 'bookmark',
            not_found    => 'bookmark not found',
            request      => {
                %{ _target_request($input) }, note => $input->{note} || q{},
            },
            run => sub {
                return $self->bookmark_store->save_bookmark(
                    _target_write($input) );
            },
        }
    );
}

sub remove_bookmark ( $self, $input ) {
    return $self->_commanded_op(
        {
            command_type => 'community.bookmark_remove',
            input        => $input,
            kind         => 'bookmark',
            not_found    => 'bookmark not found',
            request      => _target_request($input),
            run          => sub {
                return $self->bookmark_store->remove_for_user_target(
                    _target_write($input) );
            },
        }
    );
}

sub save_subscription ( $self, $input ) {
    return $self->_commanded_op(
        {
            command_type => 'community.subscribe',
            input        => $input,
            kind         => 'subscription',
            not_found    => 'subscription not found',
            request      => {
                %{ _target_request($input) },
                preference => $input->{preference} || 'all',
            },
            run => sub {
                return $self->subscription_store->save_subscription(
                    {
                        preference  => $input->{preference},
                        target_id   => $input->{target_id},
                        target_type => $input->{target_type},
                        user_id     => $input->{user_id},
                    }
                );
            },
        }
    );
}

sub mute_subscription ( $self, $input ) {
    return $self->_commanded_op(
        {
            command_type => 'community.subscription_mute',
            input        => $input,
            kind         => 'subscription',
            not_found    => 'subscription not found',
            request      => _target_request($input),
            run          => sub {
                return $self->subscription_store->mute_for_user_target(
                    _target_write($input) );
            },
        }
    );
}

sub revoke_subscription ( $self, $input ) {
    return $self->_commanded_op(
        {
            command_type => 'community.unsubscribe',
            input        => $input,
            kind         => 'subscription',
            not_found    => 'subscription not found',
            request      => _target_request($input),
            run          => sub {
                return $self->subscription_store->revoke_for_user_target(
                    _target_write($input) );
            },
        }
    );
}

# A report needs a reason, and both its reason and its details have a
# length limit.
sub create_report ( $self, $input ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    my %errors;
    my $reason = _trim( $input->{reason} );
    if ( !length $reason ) {
        $errors{reason} = 'reason is required';
    }
    if ( length $reason > $REPORT_REASON_MAX ) {
        $errors{reason} = 'reason is too long';
    }
    if ( length( _trim( $input->{details} ) ) > $REPORT_DETAILS_MAX ) {
        $errors{details} = 'details are too long';
    }
    if (%errors) {
        return _result(
            error  => 'invalid report',
            errors => \%errors,
            status => 'invalid',
        );
    }

    return $self->_commanded_op(
        {
            command_type => 'community.report',
            input        => {
                %{$input}, user_id => $input->{reporter_user_id},
            },
            kind      => 'report',
            not_found => 'report not found',
            request   => _report_request($input),
            run       => sub {
                return $self->report_store->create_report(
                    _report_request($input) );
            },
        }
    );
}

# The store's answer under the command id: a store that dies fails the
# command and is logged; one that answers nothing, or ok => 0 with its
# reason, is not found; any other answer is reduced to the public fields of
# its kind. Without a command log the write just runs.
sub _commanded_op ( $self, $job ) {
    my $invalid = $self->_missing_command_id( $job->{input} );
    if ($invalid) {
        return $invalid;
    }

    my $run = sub {
        my $value;
        try {
            $value = $job->{run}->();
        }
        catch ($error) {
            $self->_log_error("community write failed: $error");
            return _failed_result();
        };
        my $answer = ref $value eq 'HASH' ? $value : {};
        if ( !$value || ( exists $answer->{ok} && !$answer->{ok} ) ) {
            return _result(
                error  => $answer->{error} || $job->{not_found},
                status => 'not_found',
            );
        }

        return _result(
            status => 'ok',
            stored => _public_stored( $job->{kind}, $value ),
        );
    };
    if ( !$self->command_idempotency ) {
        return $run->();
    }

    my $result;
    try {
        $result = $self->command_idempotency->result_of(
            {
                actor_id     => $job->{input}{user_id},
                command_id   => $job->{input}{command_id},
                command_type => $job->{command_type},
                request      => $job->{request},
                run          => $run,
            }
        );
    }
    catch ($error) {
        $self->_log_error("community command log failed: $error");
        return _failed_result();
    };

    return $result;
}

sub _missing_command_id ( $, $input ) {
    if ( length _trim( $input->{command_id} ) ) {
        return undef;
    }

    return _result(
        errors => { command_id => 'command_id is required' },
        status => 'invalid',
    );
}

# The fields of a stored row that the answer, and the command log, carry. A
# report store may answer with its row rather than a hash.
sub _public_stored ( $kind, $stored ) {
    my @fields = @{ $PUBLIC_FIELDS{$kind} };
    if ( $kind ne 'report' ) {
        return { map { $_ => $stored->{$_} } @fields };
    }

    $stored ||= {};
    return { map { $_ => scalar _report_value( $stored, $_ ) } @fields };
}

sub _report_value ( $stored, $name ) {
    if ( ref $stored eq 'HASH' ) {
        return $stored->{$name};
    }
    if ( $stored && $stored->can('get_column') ) {
        return $stored->get_column($name);
    }

    return undef;
}

sub _target_request ($input) {
    return {
        target_id   => $input->{target_id},
        target_type => $input->{target_type},
        user_id     => $input->{user_id},
    };
}

sub _target_write ($input) {
    return {
        note        => $input->{note},
        target_id   => $input->{target_id},
        target_type => $input->{target_type},
        user_id     => $input->{user_id},
    };
}

sub _report_request ($input) {
    return {
        details          => _trim( $input->{details} ),
        reason           => _trim( $input->{reason} ),
        reporter_user_id => $input->{reporter_user_id},
        target_id        => $input->{target_id},
        target_type      => $input->{target_type},
    };
}

sub _failed_result {
    return _result(
        error  => 'community store failed',
        status => 'failed',
    );
}

sub _trim ($value) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _result (%input) {
    return {
        error  => $input{error},
        errors => $input{errors},
        ok     => ( $input{status} || q{} ) eq 'ok' ? 1 : 0,
        status => $input{status} || 'failed',
        stored => $input{stored},
    };
}

sub _log_error ( $self, $message ) {
    if ( !$self->logger ) {
        return;
    }

    $self->logger->error($message);

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Community::Workflow - Bookmark, subscription, and report writes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = $workflow->save_bookmark(
        {
            command_id  => $command_id,
            target_id   => $thread_id,
            target_type => 'thread',
            user_id     => $user_id,
        }
    );

=head1 DESCRIPTION

Application boundary for thread bookmark, subscription, and member report
writes from HTTP controllers. Requires C<command_id> and replays from
C<command_log> when the helper is present. Command hashes include actor,
target, and preference, note, or report reason fields only. Stores keep
unique-restore and persistence ownership.

=head1 SUBROUTINES/METHODS

=head2 save_bookmark

Saves or restores a thread bookmark for the member.

=head2 remove_bookmark

Soft-deletes the member bookmark for a target.

=head2 save_subscription

Saves or restores a thread subscription for the member.

=head2 mute_subscription

Mutes an existing thread subscription.

=head2 revoke_subscription

Revokes an existing thread subscription.

=head2 create_report

Creates a member report for a thread, post, or profile.

=head1 DIAGNOSTICS

Returns C<invalid>, C<not_found>, C<conflict>, or C<failed> statuses instead
of throwing for expected outcomes.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the bookmark store, subscription store, report store, and
command-idempotency helper supplied by the composition root.

=head1 DEPENDENCIES

Uses L<GPForum::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Feed and bookmark listing stay HTTP reads against the existing stores.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
