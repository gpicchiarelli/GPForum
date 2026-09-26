# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PublicCacheRequest;

use strict;
use warnings;

use Mojo::Base -base;
use Mojo::Message::Request;

our $VERSION = '0.001';

has if_modified_since => undef;
has if_none_match     => undef;
has method            => 'GET';
has session_user_id   => undef;

sub req {
    my ($self) = @_;

    my $request = Mojo::Message::Request->new;
    $request->method( $self->method );
    $self->_apply_freshness_headers($request);

    return $request;
}

sub session {
    my ( $self, $name ) = @_;

    if ( ( $name || q{} ) eq 'user_id' ) {
        return $self->session_user_id;
    }

    return;
}

sub _apply_freshness_headers {
    my ( $self, $request ) = @_;

    if ( defined $self->if_none_match ) {
        $request->headers->header( 'If-None-Match' => $self->if_none_match );
    }
    if ( defined $self->if_modified_since ) {
        $request->headers->header(
            'If-Modified-Since' => $self->if_modified_since );
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Test::PublicCacheRequest - Public cache request fake.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $controller = GPForum::Test::PublicCacheRequest->new(
        if_none_match => $etag,
        method        => 'GET',
    );

=head1 DESCRIPTION

Test double for C<Web::PublicCacheAccess> cacheability and freshness
headers.

=head1 SUBROUTINES/METHODS

=head2 req

Returns a Mojolicious request with method and conditional headers.

=head2 session

Returns the fake cookie-session user id.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Mojo::Message::Request>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not emulate signed cookie serialization.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
