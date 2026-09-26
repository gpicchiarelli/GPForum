# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::DangerConfirmation;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $CONFIRMED => '1';

# ADR 0079: destructive staff actions -- running an erasure, approving one,
# suspending an account, revoking a role -- must not be one click away from a
# routine button. The form asks the operator to tick "I understand" beside a
# sentence saying what the action does, and the server refuses the request
# without it, so neither a stray click nor a replayed form can do it. Returns
# the invalid result the controllers already turn into a 400, or undef when
# the request is confirmed.
sub unconfirmed ( $class, $controller ) {
    my $confirm = $controller->param('confirm');
    return if defined $confirm && $confirm eq $CONFIRMED;

    return {
        status => 'invalid',
        errors => {
            confirm => 'Confirm that you understand what this action does.'
        },
    };
}

1;

__END__

=head1 NAME

GPForum::Web::DangerConfirmation - Require confirmation of destructive actions.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    if ( my $refused = GPForum::Web::DangerConfirmation->unconfirmed($self) ) {
        return $self->binding_write_response( $refused, $ok_status );
    }

=head1 DESCRIPTION

Destructive staff actions carry a required C<confirm> checkbox beside a
statement of their consequence (the C<components/danger_confirm> template).
This refuses a request that does not carry C<confirm=1>.

=head1 SUBROUTINES/METHODS

=head2 unconfirmed

An C<invalid> result with a C<confirm> error, or undef when confirmed.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

It confirms intent, not identity; ADR 0079's recent re-authentication for
dangerous actions is not implemented.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
