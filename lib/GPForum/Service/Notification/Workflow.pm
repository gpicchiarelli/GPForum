# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Notification::Workflow;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

has command_idempotency => undef;
has dispatcher          => undef;
has logger              => undef;
has preference_store    => undef;

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
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_preferences($input);
}

sub _commanded_preferences ( $self, $input ) {
    return $self->_commanded_write(
        {
            actor_id     => $input->{user_id},
            command_id   => $input->{command_id},
            command_type => 'notification.preferences',
            request      => {
                preferences =>
                  _public_preference_request( $input->{preferences} ),
                user_id => $input->{user_id},
            },
            run => sub { return $self->_preference_store_write($input); },
        }
    );
}

sub _preference_store_write ( $self, $input ) {
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
        $self->_log_error("notification command log failed: $EVAL_ERROR");
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

sub _public_preference_request ($preferences) {
    my @rows;
    for my $pref ( @{ $preferences || [] } ) {
        push @rows,
          {
            channel          => $pref->{channel},
            digest_frequency => $pref->{digest_frequency},
            enabled          => $pref->{enabled} ? 1 : 0,
          };
    }

    return \@rows;
}

sub _failed_result {
    return _result(
        error  => 'notification store failed',
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

sub _run_store ( $self, $not_found, $code ) {
    my $stored = $self->_eval_store($code);
    if ( $stored->{failed} ) {
        return _result(
            error  => 'notification store failed',
            status => 'failed',
        );
    }

    return _stored_result( $not_found, $stored->{value} );
}

sub _eval_store ( $self, $code ) {
    my $value = eval { return $code->(); };
    if ($EVAL_ERROR) {
        $self->_log_error("notification write failed: $EVAL_ERROR");
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

Returns C<not_found> or C<failed> statuses instead of throwing for expected
write outcomes. Unexpected store exceptions are logged and mapped to
C<failed>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the notification dispatcher and preference store supplied by the
composition root.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

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
