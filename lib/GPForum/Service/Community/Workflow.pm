# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Community::Workflow;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $REPORT_DETAILS_MAX => 2_000;
const my $REPORT_REASON_MAX  => 80;

has bookmark_store      => undef;
has command_idempotency => undef;
has logger              => undef;
has report_store        => undef;
has subscription_store  => undef;

sub save_bookmark ( $self, $input ) {
    return $self->_commanded_op(
        {
            command_type => 'community.bookmark',
            input        => $input,
            kind         => 'bookmark',
            not_found    => 'bookmark not found',
            request      => _bookmark_request($input),
            run          => sub {
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
            request      => _subscribe_request($input),
            run          => sub {
                return $self->subscription_store->save_subscription(
                    _subscribe_write($input) );
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

sub create_report ( $self, $input ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    return $self->_create_report($input);
}

sub _create_report ( $self, $input ) {
    my $fields = $self->_report_fields($input);
    if ($fields) {
        return $fields;
    }

    return $self->_persist_report($input);
}

sub _persist_report ( $self, $input ) {
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

sub _commanded_op ( $self, $job ) {
    my $invalid = $self->_missing_command_id( $job->{input} );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_write(
        {
            actor_id     => $job->{input}{user_id},
            command_id   => $job->{input}{command_id},
            command_type => $job->{command_type},
            request      => $job->{request},
            run          => sub { return $self->_store_write($job); },
        }
    );
}

sub _store_write ( $self, $job ) {
    return _public_write_result( $job->{kind},
        $self->_run_store( $job->{not_found}, $job->{run} ),
    );
}

sub _commanded_write ( $self, $job ) {
    if ( !$self->command_idempotency ) {
        return $job->{run}->();
    }

    return $self->_idempotent_write($job);
}

sub _idempotent_write ( $self, $job ) {
    my $result = eval { return $self->command_idempotency->result_of($job); };
    if ($EVAL_ERROR) {
        $self->_log_error("community command log failed: $EVAL_ERROR");
        return _failed_result();
    }

    return $result;
}

sub _missing_command_id ( $, $input ) {
    if ( length _trim( $input->{command_id} ) ) {
        my $undefined;
        return $undefined;
    }

    return _result(
        errors => { command_id => 'command_id is required' },
        status => 'invalid',
    );
}

sub _public_write_result ( $kind, $result ) {
    if ( !$result->{ok} ) {
        return $result;
    }

    return _result(
        status => $result->{status},
        stored => _public_stored( $kind, $result->{stored} ),
    );
}

sub _public_stored ( $kind, $stored ) {
    if ( $kind eq 'bookmark' ) {
        return _public_bookmark($stored);
    }
    if ( $kind eq 'report' ) {
        return _public_report($stored);
    }

    return _public_subscription($stored);
}

sub _public_report ($stored) {
    $stored ||= {};

    return {
        created_at       => _report_value( $stored, 'created_at' ),
        details          => _report_value( $stored, 'details' ),
        reason           => _report_value( $stored, 'reason' ),
        report_id        => _report_value( $stored, 'report_id' ),
        reporter_user_id => _report_value( $stored, 'reporter_user_id' ),
        status           => _report_value( $stored, 'status' ),
        target_id        => _report_value( $stored, 'target_id' ),
        target_type      => _report_value( $stored, 'target_type' ),
    };
}

sub _report_value ( $stored, $name ) {
    my $undefined;
    if ( ref $stored eq 'HASH' ) {
        return $stored->{$name};
    }
    if ( $stored && $stored->can('get_column') ) {
        return $stored->get_column($name);
    }

    return $undefined;
}

sub _public_bookmark ($stored) {
    return {
        bookmark_id => $stored->{bookmark_id},
        created_at  => $stored->{created_at},
        deleted_at  => $stored->{deleted_at},
        note        => $stored->{note},
        ok          => $stored->{ok},
        target_id   => $stored->{target_id},
        target_type => $stored->{target_type},
        user_id     => $stored->{user_id},
    };
}

sub _public_subscription ($stored) {
    return {
        created_at      => $stored->{created_at},
        muted_at        => $stored->{muted_at},
        ok              => $stored->{ok},
        preference      => $stored->{preference},
        revoked_at      => $stored->{revoked_at},
        subscription_id => $stored->{subscription_id},
        target_id       => $stored->{target_id},
        target_type     => $stored->{target_type},
        user_id         => $stored->{user_id},
    };
}

sub _bookmark_request ($input) {
    my $request = _target_request($input);
    $request->{note} = $input->{note} || q{};

    return $request;
}

sub _subscribe_request ($input) {
    my $request = _target_request($input);
    $request->{preference} = $input->{preference} || 'all';

    return $request;
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

sub _subscribe_write ($input) {
    return {
        preference  => $input->{preference},
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

sub _report_fields ( $, $input ) {
    my $errors = _report_field_errors($input);
    if ( %{$errors} ) {
        return _result(
            error  => 'invalid report',
            errors => $errors,
            status => 'invalid',
        );
    }

    my $undefined;
    return $undefined;
}

sub _report_field_errors ($input) {
    my %errors;
    my $reason = _trim( $input->{reason} );
    if ( !length $reason ) {
        $errors{reason} = 'reason is required';
    }

    return _length_errors( \%errors, $input, $reason );
}

sub _length_errors ( $errors, $input, $reason ) {
    if ( length $reason > $REPORT_REASON_MAX ) {
        $errors->{reason} = 'reason is too long';
    }
    if ( length( _trim( $input->{details} ) ) > $REPORT_DETAILS_MAX ) {
        $errors->{details} = 'details are too long';
    }

    return $errors;
}

sub _run_store ( $self, $not_found, $code ) {
    my $stored = $self->_eval_store($code);
    if ( $stored->{failed} ) {
        return _failed_result();
    }

    return _stored_result( $not_found, $stored->{value} );
}

sub _eval_store ( $self, $code ) {
    my $value = eval { return $code->(); };
    if ($EVAL_ERROR) {
        $self->_log_error("community write failed: $EVAL_ERROR");
        return { failed => 1 };
    }

    return { value => $value };
}

sub _stored_result ( $not_found, $value ) {
    if ( !$value ) {
        return _result(
            error  => $not_found,
            status => 'not_found',
        );
    }
    if ( _is_missing($value) ) {
        return _result(
            error  => $value->{error} || $not_found,
            status => 'not_found',
        );
    }

    return _result(
        status => 'ok',
        stored => $value,
    );
}

sub _is_missing ($value) {
    if ( ref $value ne 'HASH' ) {
        return 0;
    }
    if ( !exists $value->{ok} ) {
        return 0;
    }

    return $value->{ok} ? 0 : 1;
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
    if ( !$self->logger || !$self->logger->can('error') ) {
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

Uses L<Mojo::Base>.

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
