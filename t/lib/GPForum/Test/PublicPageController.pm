# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PublicPageController;

use strict;
use warnings;

use Mojo::Base 'GPForum::Test::PublicCacheRequest';
use Mojo::Message::Response;

our $VERSION = '0.001';

# An anonymous GET as Web::PublicHttpCache sees it: a request, a response
# whose headers it sets, a page body, and the last render it asked for.
has last_render => undef;
has res         => sub { return Mojo::Message::Response->new; };

sub render_to_string {
    return '<p>page</p>';
}

sub render {
    my ( $self, %args ) = @_;

    $self->last_render( \%args );
    return 1;
}

1;
