# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::DiscoveryAccess;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $HTTP_OK              => 200;
const my $DEFAULT_FEED_LIMIT   => 25;
const my $DEFAULT_SITEMAP_ROWS => 100;

sub sitemap_limit {
    return $DEFAULT_SITEMAP_ROWS;
}

sub feed_limit ( $, $requested ) {
    return $requested || $DEFAULT_FEED_LIMIT;
}

sub render_document ( $self, $controller, $document ) {
    $controller->res->headers->content_type( $document->{content_type} );

    return $controller->render(
        data   => $document->{data},
        format => $document->{format},
        status => $self->status_code($document),
    );
}

sub status_code ( $, $document ) {
    return $document->{status} || $HTTP_OK;
}

1;

__END__

=head1 NAME

GPForum::Web::DiscoveryAccess - Discovery reader limits and document rendering.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $limit = $access->sitemap_limit;
    return $access->render_document( $controller, $document );

=head1 DESCRIPTION

Owns sitemap and Atom feed reader limits and the content-type plus body
render for crawler documents. It does not load categories or threads.
L<GPForum::Controller::Discovery> still calls the readers and
L<GPForum::Web::DiscoveryPayload>.

=head1 SUBROUTINES/METHODS

=head2 sitemap_limit

Returns the default sitemap row limit.

=head2 feed_limit

Returns a requested feed limit or the default.

=head2 render_document

Sets the content type and renders document data.

=head2 status_code

Returns the document status or HTTP 200.

=head1 DIAGNOSTICS

None. Missing reader data stays in the controller.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Document XML and Atom bodies stay in L<GPForum::Web::DiscoveryPayload>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
