# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RecordingLimiter;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has checks => sub { return []; };
has denied => sub { return {}; };

sub check {
    my ( $self, $input ) = @_;

    push @{ $self->checks }, $input;

    return { ok => exists $self->denied->{ $input->{action} } ? 0 : 1 };
}

1;

__END__

=head1 NAME

GPForum::Test::RecordingLimiter - A rate limiter double that records each check.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $limiter = GPForum::Test::RecordingLimiter->new(
        denied => { 'identity.login_account' => 1 } );

=head1 DESCRIPTION

Records every rate-limit input in C<checks> and denies the actions named in
C<denied>.

=head1 SUBROUTINES/METHODS

=head2 check

Records the input; denies it when its action is in C<denied>.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
