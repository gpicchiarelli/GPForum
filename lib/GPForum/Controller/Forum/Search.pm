# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Forum::Search;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'GPForum::Controller::Forum::Base', -signatures;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

sub search ($self) {
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

sub _search_results ( $self, $query, $filters, $limit ) {
    my $found = eval {
        return $self->gp_search_service->ranked_search(
            {
                user_id => $self->_current_user_id,
                viewer  => $self->gp_forum_viewer,
            },
            $query,
            {
                %{$filters}, limit => $self->_search_fetch_limit($limit),
            },
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->warn( 'search degraded: ' . _reason($EVAL_ERROR) );
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
            found   => $found,
            limit   => $limit,
            query   => $query,
        }
    );
}

sub _search_success ( $self, $input ) {
    my $limit    = $input->{limit};
    my $found    = $input->{found};
    my @results  = @{ $found->{results} };
    my $has_more = 0;
    if ( @results > $limit ) {
        $has_more = 1;
        while ( @results > $limit ) {
            pop @results;
        }
    }

    return $self->_search_page(
        {
            candidate_limit => $found->{candidate_limit},
            filters         => $input->{filters},
            has_more        => $has_more,
            limit           => $limit,
            more_limit => scalar $self->_search_more_limit( $has_more, $limit ),
            query      => $input->{query},
            ranking_capped => $found->{ranking_capped},
            results        => \@results,
        }
    );
}

sub _search_more_limit ( $self, $has_more, $limit ) {
    return $self->forum_access->search_more_limit( $has_more, $limit );
}

sub _search_fetch_limit ( $self, $limit ) {
    return $self->forum_access->search_fetch_limit($limit);
}

sub _search_page ( $self, $input ) {
    return $self->render_payload(
        {
            controller => $self,
            payload    => $self->gp_forum_view_model->search_page(
                candidate_limit => $input->{candidate_limit},
                filters         => $input->{filters},
                has_more        => $input->{has_more} || 0,
                limit           => $input->{limit},
                more_limit      => $input->{more_limit},
                query           => $input->{query},
                ranking_capped  => $input->{ranking_capped} || 0,
                results         => $input->{results}        || [],
                status          => $input->{status},
            ),
            status   => $HTTP_OK,
            template => 'forum/search',
        }
    );
}

sub search_autocomplete ($self) {
    my $query = $self->_trim( $self->param('q') || $self->param('prefix') );
    if ( $self->forum_access->autocomplete_too_short($query) ) {
        return $self->_autocomplete_payload( $query, [] );
    }
    if ( !$self->read_allowed('search.autocomplete') ) {
        return $self->_rate_limited;
    }

    return $self->_autocomplete_lookup($query);
}

sub _autocomplete_lookup ( $self, $query ) {
    my $rows = eval {
        return $self->gp_search_service->autocomplete(
            {
                user_id => $self->_current_user_id,
                viewer  => $self->gp_forum_viewer,
            },
            $query,
            {
                limit => $self->forum_access->autocomplete_limit(
                    $self->param('limit')
                ),
            },
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->warn(
            'autocomplete degraded: ' . _reason($EVAL_ERROR) );
        return $self->_autocomplete_payload( $query, [], 'degraded' );
    }

    return $self->_autocomplete_payload( $query, $rows );
}

# Why a search failed, for the log. DBI appends the statement and its bind
# values to its error, and those carry what the visitor typed and a member's
# id. A search cancelled at its own statement timeout is routine under load,
# so each one logged several kilobytes of that; the reason before it is what
# an operator acts on.
sub _reason ($error) {
    my ($reason) = split /\s* \[for [ ] Statement [ ]/msx, "$error", 2;
    $reason =~ s/\s+ \z//msx;

    return $reason;
}

sub _autocomplete_payload ( $self, $query, $suggestions, $status = undef ) {
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
to an empty result set on backend failure -- a search the database cancelled
at its own statement timeout included. Says so when the results were ranked
among the newest matches only.

=head2 search_autocomplete

Returns JSON autocomplete suggestions for a query prefix.

=head1 DIAGNOSTICS

Search backend failures are rendered as degraded empty results and logged as
C<search degraded: REASON> or C<autocomplete degraded: REASON>. The reason is
the error without the statement and bind values DBI appends to it, which carry
what the visitor typed.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the search service helper configured during application startup, with
C<GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS> and C<GPFORUM_SEARCH_CANDIDATE_LIMIT>.

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
