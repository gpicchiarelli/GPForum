# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Outbox::ClaimedMessage;

use JSON::MaybeXS qw(decode_json);
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

has row => sub { return {}; };

sub get_column ( $self, $column ) {
    return $self->_payload if $column eq 'payload';

    return $self->row->{$column};
}

sub apply_columns ( $self, $changes ) {
    for my $column ( keys %{$changes} ) {
        $self->row->{$column} = $changes->{$column};
    }

    return $self;
}

sub is_direct_outbox_message {
    return 1;
}

sub _payload ($self) {
    my $payload = $self->row->{payload};
    return {}       if !defined $payload || $payload eq q{};
    return $payload if ref $payload;

    my $decoded;
    try {
        $decoded = decode_json($payload);
    }
    catch ($error) {
        return {};
    };

    return ref $decoded eq 'HASH' ? $decoded : {};
}

1;

__END__

=head1 NAME

GPForum::Service::Outbox::ClaimedMessage - An outbox row claimed with plain SQL, behaving enough like a DBIx::Class row.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $message =
      GPForum::Service::Outbox::ClaimedMessage->new( row => $row_hash );

    my $payload = $message->get_column('payload');
    $message->apply_columns( { status => 'done' } );

=head1 DESCRIPTION

On PostgreSQL, L<GPForum::Service::Outbox::Dispatcher> claims a batch of
outbox rows with one SQL statement and gets plain hashes back. This class
wraps each hash so the transports and the dispatcher can treat it as a row:
C<get_column> reads a column (decoding C<payload> from JSON). It has no
C<update>: every write after the claim is the dispatcher's, made only while
the message is still that worker's, and C<apply_columns> copies into the
hash what such a write stored. C<is_direct_outbox_message> lets the
dispatcher tell these messages from the DBIx::Class rows of its resultset
claim.

=head1 SUBROUTINES/METHODS

=head2 get_column

Takes a column name. Returns that column's value from C<row>. For
C<payload> it returns a hash reference: the value itself when it is already
a reference, the decoded JSON when it decodes to a hash, and an empty hash
when it is undefined, empty, invalid JSON or not a JSON object.

=head2 apply_columns

Takes a hash reference of column changes and copies them into C<row>.
Returns the message. The dispatcher uses it after a write it has made.

=head2 is_direct_outbox_message

Returns 1.

=head1 DIAGNOSTICS

None of its own: invalid JSON in C<payload> reads as an empty hash.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<JSON::MaybeXS>, L<Mojo::Base>.

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
