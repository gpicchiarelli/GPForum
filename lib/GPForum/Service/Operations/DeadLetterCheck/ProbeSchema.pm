# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DeadLetterCheck::ProbeSchema;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

has outbox_resultset      => undef;    # optional: resultset answers undef
has dead_letter_resultset => undef;    # optional: resultset answers undef

sub resultset ( $self, $name ) {
    if ( $name eq 'OutboxMessage' ) {
        return $self->outbox_resultset;
    }
    if ( $name eq 'DeadLetter' ) {
        return $self->dead_letter_resultset;
    }

    return undef;
}

sub txn_do ( $self, $code ) {
    return $code->();
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::DeadLetterCheck::ProbeSchema - The dead-letter check's schema, over its in-memory stores.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # Built by GPForum::Service::Operations::DeadLetterCheck for its
    # simulate mode; nothing else uses it.
    my $probe = GPForum::Service::Operations::DeadLetterCheck::ProbeSchema->new;

=head1 DESCRIPTION

Answers the two resultsets the dispatcher asks for and runs a transaction's code with no transaction around it. One of the in-memory stand-ins
L<GPForum::Service::Operations::DeadLetterCheck> runs the real
L<GPForum::Service::Outbox::Dispatcher> against in its C<simulate> mode.

=head1 SUBROUTINES/METHODS

=head2 resultset

Returns the probe outbox for C<OutboxMessage>, the probe letters for C<DeadLetter>, and C<undef> for any other name.

=head2 txn_do

Runs the code and returns its result; there is no transaction.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None beyond L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

It stands in for PostgreSQL only as far as the dead-letter check needs.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
