package GPForum::Web::Access;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Web::Responder;

our $VERSION = '0.001';

sub csrf_invalid {
    my ( $self, $controller ) = @_;

    if ( $controller->validation->csrf_protect->has_error('csrf_token') ) {
        return 1;
    }

    return 0;
}

sub user_id {
    my ( $self, $controller ) = @_;

    return GPForum::Web::Responder->new->user_id($controller);
}

sub wants_json {
    my ( $self, $controller ) = @_;

    return GPForum::Web::Responder->new->wants_json($controller);
}

sub has_text {
    my ( undef, $value ) = @_;

    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Web::Access - Shared CSRF, session, and request-shape decisions.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $access = GPForum::Web::Access->new;
    if ( $access->csrf_invalid($controller) ) {
        return GPForum::Web::Guard->new->csrf_failure($controller);
    }

=head1 DESCRIPTION

Owns the HTTP decision helpers that controllers previously duplicated:
CSRF token validity, cookie-session user id, JSON negotiation, and
non-empty text. It does not render errors; L<GPForum::Web::Guard> keeps that
responsibility. It does not talk to stores or DBIx::Class.

=head1 SUBROUTINES/METHODS

=head2 csrf_invalid

Returns true when Mojolicious CSRF protection reports a missing or invalid
token.

=head2 user_id

Returns the cookie-session user id through L<GPForum::Web::Responder>.

=head2 wants_json

Returns true when the request prefers JSON.

=head2 has_text

Returns true when a defined non-empty string is present.

=head1 DIAGNOSTICS

These methods return booleans or identifiers. HTTP status mapping stays in
the calling controller or L<GPForum::Web::Guard>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<GPForum::Web::Responder>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Identity CSRF failures still render as text from the identity controller.
This object only reports whether the token is invalid.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
