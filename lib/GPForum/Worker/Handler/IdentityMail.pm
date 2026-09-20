package GPForum::Worker::Handler::IdentityMail;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $MAIL_REQUESTED => 'identity.mail.requested';
const my %SEND_METHOD => (
    email_change       => 'send_email_change',
    email_verification => 'send_email_verification',
    password_reset     => 'send_password_reset',
);

has mailer => undef;
has sink   => undef;

sub supports {
    my ( undef, $event ) = @_;

    return ( $event->{event_type} || q{} ) eq $MAIL_REQUESTED;
}

sub handle {
    my ( $self, $event ) = @_;

    my $task = $self->_task($event);
    if ( $self->sink ) {
        $self->sink->capture($task);
    }

    return $self->_deliver( $event, $task );
}

sub _deliver {
    my ( $self, $event, $task ) = @_;

    my $mail = $self->_mail($event);
    if ( !$mail ) {
        $task->{skipped} = 1;
        return $task;
    }

    return $self->_send( $mail, $task );
}

sub _mail {
    my ( $self, $event ) = @_;

    my $mail = $event->{mail};
    if ( ref $mail ne 'HASH' ) {
        return;
    }

    return $self->_complete_mail($mail);
}

sub _complete_mail {
    my ( undef, $mail ) = @_;

    if ( !_has_text( $mail->{kind} ) ) {
        return;
    }
    if ( !_has_text( $mail->{to} ) ) {
        return;
    }
    if ( !_has_text( $mail->{token} ) ) {
        return;
    }

    return $mail;
}

sub _send {
    my ( $self, $mail, $task ) = @_;

    my $method = $self->_send_method( $mail->{kind} );
    if ( !$method ) {
        $task->{skipped} = 1;
        return $task;
    }
    if ( !$self->mailer ) {
        $task->{skipped} = 1;
        return $task;
    }

    $task->{delivered} = $self->mailer->$method(
        {
            to    => $mail->{to},
            token => $mail->{token},
        }
    );

    return $task;
}

sub _send_method {
    my ( undef, $kind ) = @_;

    if ( !exists $SEND_METHOD{$kind} ) {
        return;
    }

    return $SEND_METHOD{$kind};
}

sub _task {
    my ( undef, $event ) = @_;

    my $mail = $event->{mail} || {};

    return {
        action   => 'identity.mail',
        event_id => $event->{event_id},
        kind     => $mail->{kind},
        to       => $mail->{to},
    };
}

sub _has_text {
    my ($value) = @_;

    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Worker::Handler::IdentityMail - Outbox identity mail delivery.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $handler = GPForum::Worker::Handler::IdentityMail->new(
        mailer => $mailer,
    );
    $handler->handle($event);

=head1 DESCRIPTION

Sends password-reset, email-change, and verification mail for
C<identity.mail.requested> outbox payloads. The raw token lives on the
outbox C<mail> hash, not on EventLog. Delivery is at-least-once: an
outbox retry after send and before C<mark_done> resends from that
payload. Delivery exceptions propagate so the dispatcher can retry.

=head1 SUBROUTINES/METHODS

=head2 supports

True for C<identity.mail.requested>.

=head2 handle

Delivers through L<GPForum::Service::Identity::Mailer> when a complete
mail payload is present.

=head1 DIAGNOSTICS

Mailer transport exceptions propagate to the outbox dispatcher.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the injected identity mailer, which reads C<GPFORUM_MAIL_*>.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not log the raw token. EventLog payloads must not include it.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
