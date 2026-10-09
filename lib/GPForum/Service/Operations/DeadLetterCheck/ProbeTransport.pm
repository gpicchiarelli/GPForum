# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DeadLetterCheck::ProbeTransport;

use GPForum::X;
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

has fail_ids   => sub { return {}; };
has fail_types => sub { return {}; };

sub dispatch ( $self, $message ) {
    my $outbox_id = $message->get_column('outbox_id');
    if ( $self->fail_ids->{$outbox_id} ) {
        GPForum::X->throw(
            message      => 'dead-letter-check permanent probe',
            failure_type => $self->fail_types->{$outbox_id},
        );
    }

    return undef;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::DeadLetterCheck::ProbeTransport - The dead-letter check's transport, failing chosen rows.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # Built by GPForum::Service::Operations::DeadLetterCheck for its
    # simulate mode; nothing else uses it.
    my $probe = GPForum::Service::Operations::DeadLetterCheck::ProbeTransport->new;

=head1 DESCRIPTION

Delivers nothing. A row listed in C<fail_ids> fails with an exception of the failure type C<fail_types> gives it, which L<GPForum::Service::Outbox::FailureType> reads before any message matching. One of the in-memory stand-ins
L<GPForum::Service::Operations::DeadLetterCheck> runs the real
L<GPForum::Service::Outbox::Dispatcher> against in its C<simulate> mode.

=head1 SUBROUTINES/METHODS

=head2 dispatch

Takes an outbox row. For an C<outbox_id> listed in C<fail_ids>, throws a L<GPForum::X> of the type in C<fail_types>, with the message C<dead-letter-check permanent probe>; otherwise returns undef.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::X>.

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
