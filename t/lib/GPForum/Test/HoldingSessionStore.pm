# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::HoldingSessionStore;

use Mojo::Base 'GPForum::Service::Identity::SessionStore', -signatures;
use v5.40;

our $VERSION = '0.001';

has before_revoke => undef;    # optional: without it this is the store

# A reset or a change rotates the credential and then, in the same
# transaction, revokes the member's sessions: the code runs while that
# transaction holds the credential's lock.
sub revoke_user_sessions ( $self, @arguments ) {
    my $code = $self->before_revoke;
    if ($code) {
        $self->before_revoke(undef);
        $code->();
    }

    return $self->SUPER::revoke_user_sessions(@arguments);
}

1;

__END__

=head1 NAME

GPForum::Test::HoldingSessionStore - The session store, running code before a member's sessions are revoked.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $sessions = GPForum::Test::HoldingSessionStore->new(
        before_revoke => sub { start_a_rival_reset() },
        schema        => $schema,
    );

=head1 DESCRIPTION

A L<GPForum::Service::Identity::SessionStore> whose C<revoke_user_sessions>
runs C<before_revoke> once before it revokes. A reset or a password change
calls it after rotating the credential, in the same transaction, so a race
test uses it to start a concurrent write while that transaction holds the
credential's lock.

=head1 SUBROUTINES/METHODS

=head2 revoke_user_sessions

Runs C<before_revoke> the first time, then revokes as the store does.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Identity::SessionStore>.

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
