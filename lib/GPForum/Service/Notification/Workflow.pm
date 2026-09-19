package GPForum::Service::Notification::Workflow;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Base -base;

our $VERSION = '0.001';

has dispatcher       => undef;
has logger           => undef;
has preference_store => undef;

sub mark_read {
    my ( $self, $input ) = @_;

    return $self->_run_store(
        'notification not found',
        sub {
            return $self->dispatcher->mark_read( $input->{notification_id},
                $input->{user_id} );
        },
    );
}

sub set_preferences {
    my ( $self, $input ) = @_;

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

sub _run_store {
    my ( $self, $not_found, $code ) = @_;

    my $stored = $self->_eval_store($code);
    if ( $stored->{failed} ) {
        return _result(
            error  => 'notification store failed',
            status => 'failed',
        );
    }

    return _stored_result( $not_found, $stored->{value} );
}

sub _eval_store {
    my ( $self, $code ) = @_;

    my $value = eval { return $code->(); };
    if ($EVAL_ERROR) {
        $self->_log_error("notification write failed: $EVAL_ERROR");
        return { failed => 1 };
    }

    return { value => $value };
}

sub _stored_result {
    my ( $not_found, $value ) = @_;

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

sub _is_missing {
    my ($value) = @_;

    if ( ref $value ne 'HASH' ) {
        return 0;
    }
    if ( !exists $value->{ok} ) {
        return 0;
    }

    return $value->{ok} ? 0 : 1;
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

=head2 set_preferences

Replaces the member notification channel preferences.

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
