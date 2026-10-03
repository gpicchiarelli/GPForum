# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::RequestPreference;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

sub wants_json ( $self, $controller ) {
    my $format = $controller->param('format') || q{};
    return 1 if $format eq 'json';

    my $accept = $controller->req->headers->accept || q{};
    return $accept =~ m{application/json}msx ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Web::RequestPreference - Whether a request asked for JSON rather than HTML.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    if ( GPForum::Web::RequestPreference->wants_json($controller) ) {
        return $controller->render( json => $payload );
    }

=head1 DESCRIPTION

One answer to one question that every page controller asks: render the JSON
form of the payload or the HTML page. A request wants JSON when its
C<format> parameter is C<json>, or when its C<Accept> header names
C<application/json>. Anything else gets HTML.

=head1 SUBROUTINES/METHODS

=head2 wants_json

Takes a Mojolicious controller. Returns 1 when the C<format> parameter is
C<json> or the C<Accept> header contains C<application/json>, and 0
otherwise. It can be called as a class method or on an instance.

=head1 DIAGNOSTICS

None. A missing parameter or header counts as a request for HTML.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>.

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
