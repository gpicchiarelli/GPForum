# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RecordingUserAgent;

use Mojo::Base -base, -signatures;
use v5.40;

use Mojo::Transaction::HTTP;

our $VERSION = '0.001';

# A user agent that answers every request with the same response, and
# records the URLs it was asked for.
has code    => 200;
has headers => sub { return {}; };
has urls    => sub { return []; };

sub get ( $self, $url ) {
    push @{ $self->urls }, $url;
    my $tx = Mojo::Transaction::HTTP->new;
    $tx->res->code( $self->code );
    for my $name ( sort keys %{ $self->headers } ) {
        $tx->res->headers->header( $name => $self->headers->{$name} );
    }

    return $tx;
}

1;

__END__

=head1 NAME

GPForum::Test::RecordingUserAgent - A user agent that records its requests.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $ua = GPForum::Test::RecordingUserAgent->new(
        code    => 404,
        headers => { 'X-GPForum-DB-Queries' => 2 },
    );
    my $res = $ua->get('http://127.0.0.1:1/')->result;
    my @asked = @{ $ua->urls };

=head1 DESCRIPTION

Stands in for a L<Mojo::UserAgent> where a test reads what a benchmark
requested from a running server: each C<get> is recorded and answered with a
response of the C<code> and C<headers> the agent was built with.

=head1 SUBROUTINES/METHODS

=head2 get

Records the URL; returns a L<Mojo::Transaction::HTTP> whose response has the
agent's C<code> and C<headers>.

=head2 code

The status every response answers with; 200 by default.

=head2 headers

The headers every response carries, by name.

=head2 urls

The URLs asked for, in order.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<Mojo::Transaction::HTTP>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Only C<get>, the call the hypnotoad benchmark makes.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
