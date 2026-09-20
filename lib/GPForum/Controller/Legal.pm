package GPForum::Controller::Legal;

use strict;
use warnings;

use GPForum::Web::LegalAccess;
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

sub terms {
    my ($self) = @_;

    return $self->_page('terms');
}

sub privacy {
    my ($self) = @_;

    return $self->_page('privacy');
}

sub cookies {
    my ($self) = @_;

    return $self->_page('cookies');
}

sub _page {
    my ( $self, $page ) = @_;

    my $access = GPForum::Web::LegalAccess->new;

    return $access->render_page( $self,
        $access->page_payload( $page, $self->_canonical_for($page) ) );
}

sub _canonical_for {
    my ( $self, $page ) = @_;

    return $self->gp_canonical_url->legal_url($page);
}

1;

__END__

=head1 NAME

GPForum::Controller::Legal - Public terms, privacy, and cookie pages.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/legal/terms')->to('Legal#terms');

=head1 DESCRIPTION

Renders the public legal pages. HTTP policy and payload shape live on
L<GPForum::Web::LegalAccess>. Canonical URLs come from
L<GPForum::Service::Discovery::CanonicalUrl>.

=head1 SUBROUTINES/METHODS

=head2 terms

Renders the terms of use.

=head2 privacy

Renders the privacy notice.

=head2 cookies

Renders the cookie notice.

=head1 DIAGNOSTICS

Rendering errors are reported by Mojolicious.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the canonical URL helper configured during application startup.

=head1 DEPENDENCIES

Uses L<Mojolicious::Controller> and L<GPForum::Web::LegalAccess>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Copy describes how this software behaves. A deployed instance still needs
operator-reviewed policy text.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
