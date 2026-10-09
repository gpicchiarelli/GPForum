# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::InterposingSessionToken;

use Mojo::Base 'GPForum::Service::SessionToken', -signatures;
use v5.40;

our $VERSION = '0.001';

has interpose => undef;    # optional: without it this is the token service

# The session store mints the token inside the transaction that inserts the
# session, so the code runs while that transaction is open.
sub issue_token ($self) {
    my $code = $self->interpose;
    if ($code) {
        $self->interpose(undef);
        $code->();
    }

    return $self->SUPER::issue_token;
}

1;

__END__

=head1 NAME

GPForum::Test::InterposingSessionToken - The session token service, running code inside the session's transaction.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $tokens = GPForum::Test::InterposingSessionToken->new(
        interpose => sub { start_a_rival_reset() },
    );

=head1 DESCRIPTION

A L<GPForum::Service::SessionToken> whose C<issue_token> runs C<interpose>
once before it mints. The session store mints inside the transaction that
inserts the session, so a race test uses it to start a concurrent write while
a login's transaction is open.

=head1 SUBROUTINES/METHODS

=head2 issue_token

Runs C<interpose> the first time, then mints as the service does.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::SessionToken>.

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
