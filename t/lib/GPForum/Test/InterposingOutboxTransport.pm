# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::InterposingOutboxTransport;

use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Test::OutboxFailure;

our $VERSION = '0.001';

has before    => sub { return {}; };
has delivered => sub { return []; };
has fail_ids  => sub { return {}; };

# The code named for a message runs first, once, while this worker is in the
# middle of dispatching it; then the message is delivered, or fails when its
# id is in fail_ids.
sub dispatch ( $self, $message ) {
    my $outbox_id = $message->get_column('outbox_id');
    my $code      = delete $self->before->{$outbox_id};
    if ($code) {
        $code->();
    }
    if ( $self->fail_ids->{$outbox_id} ) {
        GPForum::Test::OutboxFailure->throw( 'boom',
            $self->fail_ids->{$outbox_id} );
    }
    push @{ $self->delivered }, $outbox_id;

    return;
}

1;

__END__

=head1 NAME

GPForum::Test::InterposingOutboxTransport - An outbox transport that runs code in the middle of a dispatch.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $transport = GPForum::Test::InterposingOutboxTransport->new(
        before => { $outbox_id => sub { $rival->dispatch_pending(10) } },
    );

=head1 DESCRIPTION

A transport for race tests: before it dispatches a message named in
C<before> it runs that code once, so a rival worker can act while this one
is busy with the message. A message whose id is in C<fail_ids> then fails
with that failure type; any other is appended to C<delivered>.

=head1 SUBROUTINES/METHODS

=head2 dispatch

Runs the message's C<before> code, then fails or records the delivery.

=head1 DIAGNOSTICS

Throws L<GPForum::Test::OutboxFailure> for a message in C<fail_ids>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Test::OutboxFailure>.

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
