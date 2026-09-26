# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::Mailer;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $DEFAULT_FROM => 'noreply@localhost';
const my $DEFAULT_BASE => 'http://127.0.0.1:3000';
const my $DEFAULT_PORT => 587;

has config       => undef;
has from_address => sub {
    my ($self) = @_;

    return $self->_config_value( 'mail_from', $DEFAULT_FROM );
};
has logger          => undef;
has public_base_url => sub {
    my ($self) = @_;

    return $self->_config_value( 'public_base_url', $DEFAULT_BASE );
};
has transport => sub {
    my ($self) = @_;

    return $self->_build_transport;
};

sub from_config ( $class, $config ) {
    return $class->new( config => $config );
}

sub send_password_reset ( $self, $input ) {
    return $self->_send_identity_mail(
        {
            body    => $self->_password_reset_body($input),
            kind    => 'password_reset',
            subject => 'Reset your GPForum password',
            to      => $input->{to},
        }
    );
}

sub send_email_change ( $self, $input ) {
    return $self->_send_identity_mail(
        {
            body    => $self->_email_change_body($input),
            kind    => 'email_change',
            subject => 'Confirm your GPForum email change',
            to      => $input->{to},
        }
    );
}

sub send_email_verification ( $self, $input ) {
    return $self->_send_identity_mail(
        {
            body    => $self->_email_verification_body($input),
            kind    => 'email_verification',
            subject => 'Verify your GPForum account',
            to      => $input->{to},
        }
    );
}

sub _send_identity_mail ( $self, $input ) {
    my $email = $self->_build_email($input);
    return $self->_deliver_email( $email, $input );
}

sub _build_email ( $self, $input ) {
    require Email::Simple;
    return Email::Simple->create(
        body   => $input->{body},
        header => [
            'Content-Type' => 'text/plain; charset=UTF-8',
            From           => $self->from_address,
            Subject        => $input->{subject},
            To             => $input->{to},
        ],
    );
}

sub _deliver_email ( $self, $email, $input ) {
    $self->transport->send(
        $email,
        {
            from => $self->from_address,
            to   => [ $input->{to} ],
        }
    );
    $self->_log_sent( $input->{kind} );

    return { ok => 1 };
}

sub _password_reset_body ( $self, $input ) {
    my $link = $self->_absolute_url( '/password/reset/' . $input->{token} );
    return $self->_link_body(
        'A password reset was requested for your GPForum account.', $link );
}

sub _email_change_body ( $self, $input ) {
    my $link = $self->_absolute_url( '/email/confirm/' . $input->{token} );
    return $self->_link_body(
        'Confirm the new email address for your GPForum account.', $link );
}

sub _email_verification_body ( $self, $input ) {
    my $link = $self->_absolute_url( '/email/verify/' . $input->{token} );
    return $self->_link_body(
        'Verify this email address to activate your GPForum account.', $link );
}

sub _link_body ( $, $intro, $link ) {
    return join "\n\n", $intro, $link,
      'If you did not request this, you can ignore this message.';
}

sub _absolute_url ( $self, $path ) {
    my $base = $self->public_base_url;
    $base =~ s{ / \z}{}msx;

    return $base . $path;
}

sub _build_transport ($self) {
    my $name = $self->_config_value( 'mail_transport', 'test' );
    return $self->_transport_for($name);
}

sub _transport_for ( $self, $name ) {
    if ( $name eq 'smtp' ) {
        return $self->_smtp_transport;
    }
    if ( $name eq 'sendmail' ) {
        return $self->_sendmail_transport;
    }

    return $self->_test_transport;
}

sub _smtp_transport ($self) {
    require Email::Sender::Transport::SMTP;
    return Email::Sender::Transport::SMTP->new( $self->_smtp_args );
}

sub _sendmail_transport ($self) {
    require Email::Sender::Transport::Sendmail;
    return Email::Sender::Transport::Sendmail->new;
}

sub _test_transport ($self) {
    require Email::Sender::Transport::Test;
    return Email::Sender::Transport::Test->new;
}

sub _smtp_args ($self) {
    my $args = {
        host => $self->_config_value( 'smtp_host', 'localhost' ),
        port => int $self->_config_value( 'smtp_port', $DEFAULT_PORT ),
    };
    $self->_apply_smtp_ssl($args);
    $self->_apply_smtp_auth($args);

    return $args;
}

sub _apply_smtp_ssl ( $self, $args ) {
    if ( !$self->_config_value( 'smtp_ssl', 0 ) ) {
        return;
    }

    $args->{ssl} = 'starttls';
    return;
}

sub _apply_smtp_auth ( $self, $args ) {
    my $user = $self->_config_value( 'smtp_username', q{} );
    if ( !$user ) {
        return;
    }

    $args->{sasl_username} = $user;
    $args->{sasl_password} = $self->_config_value( 'smtp_password', q{} );
    return;
}

sub _config_value ( $self, $name, $default ) {
    my $config = $self->config;
    if ( !$config || !$config->can($name) ) {
        return $default;
    }

    return $self->_present_or_default( $config->$name, $default );
}

sub _present_or_default ( $, $value, $default ) {
    if ( !defined $value ) {
        return $default;
    }
    if ( !length $value ) {
        return $default;
    }

    return $value;
}

sub _log_sent ( $self, $kind ) {
    $self->_log( 'info', "identity mail delivered: $kind" );
    return;
}

sub _log ( $self, $level, $message ) {
    if ( !$self->logger || !$self->logger->can($level) ) {
        return;
    }

    $self->logger->$level($message);
    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::Mailer - Identity transactional mail delivery.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $mailer = GPForum::Service::Identity::Mailer->from_config($config);
    $mailer->send_password_reset(
        {
            to    => $email,
            token => $raw_token,
        }
    );

=head1 DESCRIPTION

Sends password-reset, email-change, and registration-verification messages
through L<Email::Sender> transports. The transport is injectable so tests
can use L<Email::Sender::Transport::Test>. Configuration comes from
L<GPForum::Config>: C<test>, C<smtp>, or C<sendmail>. Raw tokens are placed
only in the message body and are never written to logs. Delivery uses the
transport C<send> method so C<Email::Sender::Simple> is not required at
runtime.

=head1 SUBROUTINES/METHODS

=head2 from_config

Builds a mailer from a L<GPForum::Config> object.

=head2 send_password_reset

Sends a reset link for the supplied recipient and raw token.

=head2 send_email_change

Sends an email-change confirmation link.

=head2 send_email_verification

Sends a registration verification link.

=head1 DIAGNOSTICS

Transport send exceptions propagate to the caller. Delivery success is
logged as C<identity mail delivered: $kind> without the token.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<mail_transport>, C<mail_from>, C<public_base_url>, and optional
SMTP fields from the injected config object.

=head1 DEPENDENCIES

Uses L<Email::Simple> and L<Email::Sender> transports. Transports are
loaded when they are built.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not queue mail through the outbox. The identity worker handler
sends after the token transaction commits an outbox row.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
