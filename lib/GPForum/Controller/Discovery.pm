package GPForum::Controller::Discovery;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my $HTTP_OK              => 200;
const my $DEFAULT_FEED_LIMIT   => 25;
const my $DEFAULT_SITEMAP_ROWS => 100;

sub robots {
    my ($self) = @_;

    $self->res->headers->content_type('text/plain; charset=utf-8');

    return $self->render(
        data   => $self->gp_robots_policy->render,
        format => 'txt',
        status => $HTTP_OK,
    );
}

sub sitemap {
    my ($self) = @_;

    my $categories = $self->gp_category_reader->list_categories(
        { limit => $DEFAULT_SITEMAP_ROWS } );
    my $threads = $self->gp_thread_reader->list_public_threads(
        { limit => $DEFAULT_SITEMAP_ROWS } );

    my $builder = $self->gp_sitemap_builder;
    my @entries = (
        @{
            $builder->category_entries(
                $self->gp_discovery_view_model->resources($categories)
            )
        },
        @{
            $builder->thread_entries(
                $self->gp_discovery_view_model->resources( $threads->{items} )
            )
        },
    );

    $self->res->headers->content_type('application/xml; charset=utf-8');

    return $self->render(
        data   => $builder->render_xml( \@entries ),
        format => 'xml',
        status => $HTTP_OK,
    );
}

sub feed {
    my ($self) = @_;

    my $page = $self->gp_thread_reader->list_public_threads(
        { limit => $self->param('limit') || $DEFAULT_FEED_LIMIT } );
    my $items =
      $self->gp_feed_builder->thread_items(
        $self->gp_discovery_view_model->resources( $page->{items} ) );
    my $updated =
      @{$items} ? $items->[0]{updated} : $self->gp_clock->now_iso8601;
    my $url = $self->gp_canonical_url->base_url . '/feed.atom';

    $self->res->headers->content_type('application/atom+xml; charset=utf-8');

    return $self->render(
        data => $self->gp_feed_builder->render_atom(
            {
                id      => $url,
                title   => 'GPForum public discussions',
                url     => $url,
                updated => $updated,
                items   => $items,
            }
        ),
        format => 'atom',
        status => $HTTP_OK,
    );
}

1;
