package GPForum::Test::MailerLog;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has lines => sub { return []; };

sub info {
    my ( $self, $message ) = @_;

    push @{ $self->lines }, $message;
    return;
}

sub error {
    my ( $self, $message ) = @_;

    push @{ $self->lines }, $message;
    return;
}

1;

__END__

=head1 NAME

GPForum::Test::MailerLog - Recording logger for mailer tests.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $logger = GPForum::Test::MailerLog->new;

=head1 DESCRIPTION

Captures C<info> and C<error> lines so identity mailer tests can assert
that raw tokens are not logged.

=head1 SUBROUTINES/METHODS

=head2 info

Records an info line.

=head2 error

Records an error line.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not implement other log levels.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
