# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Notification::Workflow;

use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

has command_idempotency => undef;    # optional: writes run unlogged without one
__PACKAGE__->requires(qw(dispatcher preference_store));
has logger => undef;                 # optional: errors are dropped without one

sub mark_read ( $self, $input ) {
    return $self->_run_store(
        'notification not found',
        sub {
            return $self->dispatcher->mark_read( $input->{notification_id},
                $input->{user_id} );
        },
    );
}

sub mark_all_read ( $self, $input ) {
    return $self->_run_store(
        'notification inbox not found',
        sub {
            return $self->dispatcher->mark_all_read( $input->{user_id} );
        },
    );
}

sub set_preferences ( $self, $input ) {
    if ( !length _trim( $input->{command_id} ) ) {
        return _result(
            errors => { command_id => 'command_id is required' },
            status => 'invalid',
        );
    }

    my $run = sub {
        return $self->_run_store(
            'notification preferences not found',
            sub {
                return $self->preference_store->set_preferences(
                    {
                        preferences => $input->{preferences},
                        user_id     => $input->{user_id},
                    }
                );
            },
        );
    };
    if ( !$self->command_idempotency ) {
        return $run->();
    }

    my @preferences = map {
        +{
            channel          => $_->{channel},
            digest_frequency => $_->{digest_frequency},
            enabled          => $_->{enabled} ? 1 : 0,
        }
    } @{ $input->{preferences} || [] };
    my $result;
    try {
        $result = $self->command_idempotency->result_of(
            {
                actor_id     => $input->{user_id},
                command_id   => $input->{command_id},
                command_type => 'notification.preferences',
                request      => {
                    preferences => \@preferences,
                    user_id     => $input->{user_id},
                },
                run => $run,
            }
        );
    }
    catch ($error) {
        $self->_log_error("notification command log failed: $error");
        return _result(
            error  => 'notification store failed',
            status => 'failed',
        );
    };

    return $result;
}

sub _trim ($value) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

# A store that dies fails the write and is logged; one that answers nothing,
# or ok => 0 with its reason, is not found. A store that refused the input
# (an unknown notification channel) is an invalid request, not a missing
# row: read as not_found, the refusal would answer the settings form with a
# 500 and log a degraded store.
sub _run_store ( $self, $not_found, $code ) {
    my $value;
    try {
        $value = $code->();
    }
    catch ($error) {
        $self->_log_error("notification write failed: $error");
        return _result(
            error  => 'notification store failed',
            status => 'failed',
        );
    };
    my $answer = ref $value eq 'HASH' ? $value : {};
    if ( !$value ) {
        return _result(
            error  => $not_found,
            status => 'not_found',
        );
    }
    if ( ( $answer->{status} // q{} ) eq 'invalid' ) {
        return _result(
            error  => $answer->{error},
            errors => $answer->{errors},
            status => 'invalid',
        );
    }
    if ( exists $answer->{ok} && !$answer->{ok} ) {
        return _result(
            error  => $answer->{error} || $not_found,
            status => 'not_found',
        );
    }

    return _result(
        status => 'ok',
        stored => $value,
    );
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

GPForum::Service::Notification::Workflow - Notification inbox writes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = $workflow->mark_read(
        {
            notification_id => $notification_id,
            user_id         => $user_id,
        }
    );

=head1 DESCRIPTION

Application boundary for notification inbox and preference writes. Delegates
persistence to the existing dispatcher and preference store and returns a
normalized result hash. Those services keep transaction and projection
ownership.

=head1 SUBROUTINES/METHODS

=head2 mark_read

Marks a recipient inbox row read or reports it missing.

=head2 mark_all_read

Marks every unread inbox row for the member. An empty inbox is success with
C<marked_count> 0.

=head2 set_preferences

Replaces the member notification channel preferences. Requires
C<command_id> and replays from C<command_log> when the helper is present.

=head1 DIAGNOSTICS

Returns C<invalid>, C<not_found> or C<failed> statuses instead of throwing
for expected write outcomes: C<invalid> (with the store's C<error> and
C<errors>) when the preference store refused the input, such as an unknown
channel. Unexpected store exceptions are logged and mapped to C<failed>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the notification dispatcher and preference store supplied by the
composition root.

=head1 DEPENDENCIES

Uses L<GPForum::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Inbox and mention reads stay on HTTP controllers and the dispatcher/reader
helpers. Channel catalogs remain on the preference store.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
