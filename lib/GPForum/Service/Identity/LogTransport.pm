# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::LogTransport;

use Carp qw(croak);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(encode);

use GPForum::Service::I18N::CliCatalog;

our $VERSION = '0.001';

has catalog => sub { return GPForum::Service::I18N::CliCatalog->new; };

# Standard error stands in for a log, so a command's standard output -- its
# --json document, say -- stays its own.
has logger => undef;    # optional: without one the message goes to stderr

# GPFORUM_MAIL_TRANSPORT=log: the message, its link included, written where
# the developer reads it instead of sent anywhere. Development's default, so
# an account can be verified on a laptop with no mail server; Config refuses
# it in staging and production, where it would print members' tokens.
sub send ( $self, $email, $envelope ) {    ## no critic (Subroutines::ProhibitBuiltinHomonyms) -- the method Email::Sender transports answer to
       # Email::Simple keeps the body with the CRLF line ends mail is sent with;
       # a log reads it with plain ones, and without trailing blank lines.
    my $body = $email->body =~ s/\r\n/\n/grmsx;
    $body =~ s/\s+\z//msx;

    my $text = join "\n",
      $self->catalog->text( 'mail.log_transport',
        { transport_variable => 'GPFORUM_MAIL_TRANSPORT' } ),
      'To: ' . join( q{, }, @{ $envelope->{to} // [] } ),
      'Subject: ' . ( $email->header('Subject') // q{} ),
      q{},
      $body;

    if ( $self->logger ) {
        $self->logger->info($text);
        return 1;
    }

    print {*STDERR} encode( 'UTF-8', "$text\n" )
      or croak 'failed to write the mail to standard error';

    return 1;
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::LogTransport - Mail written to the log, not sent.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $mailer = GPForum::Service::Identity::Mailer->new(
        transport => GPForum::Service::Identity::LogTransport->new(
            logger => $app->log ),
    );

=head1 DESCRIPTION

The C<log> mail transport (C<GPFORUM_MAIL_TRANSPORT=log>), development's
default. Each message -- a line saying it was not sent, its recipients, its
subject and its body with the link -- is written to the logger, or to
standard error without one. Nothing leaves the host, so a laptop without a
mail server can still follow a verification or reset link.
L<GPForum::Config> refuses it in staging and production: the body carries a
member's raw token.

=head1 SUBROUTINES/METHODS

=head2 send

Takes an L<Email::Simple> message and an envelope hash reference with C<to>,
as an L<Email::Sender> transport does, writes the message and returns true.

=head1 DIAGNOSTICS

Croaks C<failed to write the mail to standard error> when standard error
cannot be written.

=head1 CONFIGURATION AND ENVIRONMENT

The line saying the message was not sent follows the operator's language
(L<GPForum::Service::I18N::CliCatalog>).

=head1 DEPENDENCIES

L<Mojo::Base>, L<Mojo::Util>, L<GPForum::Service::I18N::CliCatalog>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The message is written as plain text; a multipart message would be written
whole.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
