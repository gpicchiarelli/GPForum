package GPForum::Test::IdentityMailer;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has sent => sub { return []; };

sub send_password_reset {
    my ( $self, $input ) = @_;

    return $self->_record( 'password_reset', $input );
}

sub send_email_change {
    my ( $self, $input ) = @_;

    return $self->_record( 'email_change', $input );
}

sub send_email_verification {
    my ( $self, $input ) = @_;

    return $self->_record( 'email_verification', $input );
}

sub _record {
    my ( $self, $kind, $input ) = @_;

    push @{ $self->sent },
      {
        kind  => $kind,
        to    => $input->{to},
        token => $input->{token},
      };

    return { ok => 1 };
}

1;

__END__

=head1 NAME

GPForum::Test::IdentityMailer - Recording identity mailer.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $mailer = GPForum::Test::IdentityMailer->new;

=head1 DESCRIPTION

Test double that records identity mail commands without L<Email::Sender>
or C<Crypt::URandom>.

=head1 SUBROUTINES/METHODS

=head2 send_password_reset

Records a password-reset command.

=head2 send_email_change

Records an email-change command.

=head2 send_email_verification

Records a verification command.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not emulate transport failures.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
