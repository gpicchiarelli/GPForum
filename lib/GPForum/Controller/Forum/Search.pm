package GPForum::Controller::Forum::Search;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'GPForum::Controller::Forum::Base';

our $VERSION = '0.001';

const my $HTTP_OK => 200;

sub search {
    my ($self) = @_;

    if ( !$self->read_allowed('search') ) {
        return $self->_rate_limited;
    }

    my $query   = $self->_trim( $self->param('q') );
    my $filters = $self->search_filters;
    my $limit = $self->forum_access->search_page_limit( $self->param('limit') );

    if ( !length $query ) {
        return $self->_search_page(
            {
                filters => $filters,
                limit   => $limit,
                query   => q{},
                results => [],
            }
        );
    }

    return $self->_search_results( $query, $filters, $limit );
}

sub _search_results {
    my ( $self, $query, $filters, $limit ) = @_;

    my $rows = eval {
        return $self->gp_search_service->search(
            { user_id => $self->_current_user_id },
            $query,
            {
                %{$filters}, limit => $self->_search_fetch_limit($limit),
            },
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->warn("search degraded: $EVAL_ERROR");
        return $self->_search_page(
            {
                filters => $filters,
                limit   => $limit,
                query   => $query,
                results => [],
                status  => 'degraded',
            }
        );
    }

    return $self->_search_success(
        {
            filters => $filters,
            limit   => $limit,
            query   => $query,
            rows    => $rows,
        }
    );
}

sub _search_success {
    my ( $self, $input ) = @_;

    my $limit    = $input->{limit};
    my @results  = @{ $input->{rows} };
    my $has_more = 0;
    if ( @results > $limit ) {
        $has_more = 1;
        while ( @results > $limit ) {
            pop @results;
        }
    }

    return $self->_search_page(
        {
            filters    => $input->{filters},
            has_more   => $has_more,
            limit      => $limit,
            more_limit => scalar $self->_search_more_limit( $has_more, $limit ),
            query      => $input->{query},
            results    => \@results,
        }
    );
}

sub _search_more_limit {
    my ( $self, $has_more, $limit ) = @_;

    return $self->forum_access->search_more_limit( $has_more, $limit );
}

sub _search_fetch_limit {
    my ( $self, $limit ) = @_;

    return $self->forum_access->search_fetch_limit($limit);
}

sub _search_page {
    my ( $self, $input ) = @_;

    return $self->render_payload(
        {
            controller => $self,
            payload    => $self->gp_forum_view_model->search_page(
                filters    => $input->{filters},
                has_more   => $input->{has_more} || 0,
                limit      => $input->{limit},
                more_limit => $input->{more_limit},
                query      => $input->{query},
                results    => $input->{results} || [],
                status     => $input->{status},
            ),
            status   => $HTTP_OK,
            template => 'forum/search',
        }
    );
}

sub search_autocomplete {
    my ($self) = @_;

    my $query = $self->_trim( $self->param('q') || $self->param('prefix') );
    if ( $self->forum_access->autocomplete_too_short($query) ) {
        return $self->_autocomplete_payload( $query, [] );
    }
    if ( !$self->read_allowed('search.autocomplete') ) {
        return $self->_rate_limited;
    }

    return $self->_autocomplete_lookup($query);
}

sub _autocomplete_lookup {
    my ( $self, $query ) = @_;

    my $rows = eval {
        return $self->gp_search_service->autocomplete(
            { user_id => $self->_current_user_id },
            $query,
            {
                limit => $self->forum_access->autocomplete_limit(
                    $self->param('limit')
                ),
            },
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->warn("autocomplete degraded: $EVAL_ERROR");
        return $self->_autocomplete_payload( $query, [], 'degraded' );
    }

    return $self->_autocomplete_payload( $query, $rows );
}

sub _autocomplete_payload {
    my ( $self, $query, $suggestions, $status ) = @_;

    return $self->render(
        json => $self->gp_forum_view_model->autocomplete_response(
            query       => $query,
            suggestions => $suggestions,
            status      => $status,
        ),
        status => $HTTP_OK,
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Forum::Search - Forum search and autocomplete.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/search')->to('Forum::Search#search');

=head1 DESCRIPTION

Renders search results and JSON autocomplete suggestions. Page and
autocomplete limits live on L<GPForum::Web::ForumAccess>. Search backend
failures stay logged here.

=head1 SUBROUTINES/METHODS

=head2 search

Renders the search page after the C<forum_retrieval> rate limit, degrading
to an empty result set on backend failure.

=head2 search_autocomplete

Returns JSON autocomplete suggestions for a query prefix.

=head1 DIAGNOSTICS

Search backend failures are logged and rendered as degraded empty results.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the search service helper configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Forum::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

HTML search and autocomplete are rate-limited independently.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
