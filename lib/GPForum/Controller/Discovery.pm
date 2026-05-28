package GPForum::Controller::Discovery;

use strict;
use warnings;

use Const::Fast;
use GPForum::Web::DiscoveryPayload;
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my $HTTP_OK              => 200;
const my $DEFAULT_FEED_LIMIT   => 25;
const my $DEFAULT_SITEMAP_ROWS => 100;

sub robots {
    my ($self) = @_;

    return _render_document(
        $self,
        GPForum::Web::DiscoveryPayload->robots(
            policy => $self->gp_robots_policy,
        )
    );
}

sub sitemap {
    my ($self) = @_;

    my $categories = $self->gp_category_reader->list_categories(
        { limit => $DEFAULT_SITEMAP_ROWS } );
    my $threads = $self->gp_thread_reader->list_public_threads(
        { limit => $DEFAULT_SITEMAP_ROWS } );

    return _render_document(
        $self,
        GPForum::Web::DiscoveryPayload->sitemap(
            builder    => $self->gp_sitemap_builder,
            categories => $categories,
            presenter  => $self->gp_discovery_view_model,
            threads    => $threads,
        )
    );
}

sub feed {
    my ($self) = @_;

    my $page = $self->gp_thread_reader->list_public_threads(
        { limit => $self->param('limit') || $DEFAULT_FEED_LIMIT } );

    return _render_document(
        $self,
        GPForum::Web::DiscoveryPayload->feed(
            builder       => $self->gp_feed_builder,
            canonical_url => $self->gp_canonical_url,
            clock         => $self->gp_clock,
            page          => $page,
            presenter     => $self->gp_discovery_view_model,
        )
    );
}

sub _render_document {
    my ( $controller, $document ) = @_;

    $controller->res->headers->content_type( $document->{content_type} );

    return $controller->render(
        data   => $document->{data},
        format => $document->{format},
        status => $document->{status} || $HTTP_OK,
    );
}

1;
