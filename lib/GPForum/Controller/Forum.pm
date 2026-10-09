# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Forum;

use Const::Fast;
use Mojo::Base 'GPForum::Controller::Forum::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

# The index lists what the reader makes of the request's limit (100 without
# one), so its cache key names that limit. It named a thread list's page
# size, 25 when none was asked: /categories?limit=25 and /categories shared
# an entry, and whichever came first was served to both. Then it named the
# limit as asked, and every spelling of the full index (no limit, ?limit=abc,
# ?limit=100, ?limit=999) was an entry of its own.
sub categories ($self) {
    my $limit =
      $self->forum_access->category_list_limit( $self->param('limit') );
    my $cache = $self->public_cache_options( 'categories', ['forum:categories'],
        { limit => $limit } );
    return if $self->served_from_public_cache($cache);

    my $categories = $self->gp_category_reader->list_categories(
        {
            limit  => $limit,
            viewer => $self->gp_forum_viewer,
        }
    );
    my $payload =
      $self->gp_forum_view_model->categories_page( categories => $categories );

    return $self->render_payload(
        {
            cache_options => $cache,
            controller    => $self,
            payload       => $payload,
            status        => $HTTP_OK,
            template      => 'forum/categories',
        }
    );
}

sub category ($self) {
    my $category_id = $self->param('category_id');
    my $cache       = $self->public_cache_options( 'category',
        [ 'forum:categories', "forum:category:$category_id" ] );
    return if $self->served_from_public_cache($cache);

    my $viewer = $self->gp_forum_viewer;
    my $category =
      $self->gp_category_reader->find_category( $category_id, $viewer );

    if ( !$category ) {
        return $self->_not_found('category not found');
    }

    # Its id written as PostgreSQL also reads a uuid (upper case, braces, no
    # hyphens) found it too, and each spelling keyed an entry of its own.
    my $own_id = $self->_column( $category, 'category_id' );
    if ( $category_id ne $own_id ) {
        return $self->gp_public_http_cache->redirect_permanently( $self,
            $self->url_for( 'category', category_id => $own_id )
              ->path->to_string );
    }

    my $user_id = $self->_current_user_id;
    my $threads = $self->gp_thread_reader->list_category_threads(
        {
            category_id    => $category_id,
            limit          => $self->list_page_limit,
            after          => $self->param('after'),
            viewer_user_id => $user_id,
            viewer_scope   => $viewer->within(
                $self->_column( $category, 'category_id' ),
                $self->_column( $category, 'space_id' )
            ),
        }
    );

    my $payload = $self->gp_forum_view_model->category_page(
        category                   => $category,
        threads_page               => $threads,
        restore_thread_command_ids =>
          $self->_restore_thread_command_ids( $threads, $user_id ),
        viewer_user_id => $user_id,
    );

    return $self->render_payload(
        {
            cache_options => $cache,
            controller    => $self,
            payload       => $payload,
            status        => $HTTP_OK,
            template      => 'forum/category',
        }
    );
}

# /t/ID and /t/ID/SLUG are one page, cached under /t/ID. A slug that is not
# the thread's, or its id spelled another way, is sent to the thread's own
# URL: the key named the path, so every slug anyone typed after the id, and
# every casing of the id, minted an entry of its own.
sub thread ($self) {
    my $thread_id = $self->param('thread_id');
    my $cache     = $self->_thread_cache_options($thread_id);
    return if $self->served_from_public_cache($cache);

    my $user_id = $self->_current_user_id;
    my $page    = $self->gp_thread_detail_reader->thread_page(
        {
            thread_id      => $thread_id,
            limit          => $self->list_page_limit,
            after          => $self->param('after'),
            viewer         => $self->gp_forum_viewer,
            viewer_user_id => $user_id,
        }
    );

    if ( !$page->{ok} ) {
        return $self->_not_found('thread not found');
    }

    my $canonical = $self->_thread_canonical_path( $page->{thread} );
    if ( $self->_is_another_spelling( $page->{thread} ) ) {
        return $self->gp_public_http_cache->redirect_permanently( $self,
            $canonical );
    }
    if ($cache) {
        $cache->{canonical_path} = $canonical;
    }

    my $payload = $self->thread_page_payload( $page, $user_id );
    if ( $self->wants_fragment ) {
        return $self->render_payload(
            {
                controller => $self,
                payload    => {
                    %{$payload}, fragment => { pagination => 1, posts => 1 },
                },
                status   => $HTTP_OK,
                template => 'forum/thread_fragment',
            }
        );
    }

    return $self->render_payload(
        {
            cache_options => $cache,
            controller    => $self,
            payload       => $payload,
            status        => $HTTP_OK,
            template      => 'forum/thread',
        }
    );
}

# Keyed by the thread's id path whatever slug the request names. A request
# that names one asks the cache to check it against the cached page's own.
sub _thread_cache_options ( $self, $thread_id ) {
    my $cache = $self->public_cache_options(
        'thread',
        ["forum:thread:$thread_id"],
        {
            path => $self->url_for( 'thread', thread_id => $thread_id )
              ->path->to_string,
        }
    );
    if ( $cache && defined $self->_requested_slug ) {
        $cache->{canonical_only} = 1;
    }

    return $cache;
}

# The path sitemaps, feeds and the page's canonical link name: /t/ID/SLUG.
# A thread without a slug (none is created without one) has only /t/ID, and
# any slug named after it is sent there.
sub _thread_canonical_path ( $self, $thread ) {
    my $thread_id = $self->_column( $thread, 'thread_id' );
    my $slug      = $self->_column( $thread, 'slug' ) // q{};
    if ( !length $slug ) {
        return $self->url_for( 'thread', thread_id => $thread_id )
          ->path->to_string;
    }

    return $self->url_for(
        'thread_canonical',
        slug      => $slug,
        thread_id => $thread_id,
    )->path->to_string;
}

# Another spelling of the thread's URL: a slug that is not its own, or its id
# written as PostgreSQL also reads a uuid (upper case, braces, no hyphens).
# Each was served under a key of its own.
sub _is_another_spelling ( $self, $thread ) {
    return 1
      if $self->param('thread_id') ne $self->_column( $thread, 'thread_id' );

    my $requested = $self->_requested_slug;
    return 0 if !defined $requested;

    return $requested eq ( $self->_column( $thread, 'slug' ) // q{} ) ? 0 : 1;
}

# The slug in the path, not a query parameter of that name: /t/ID?slug=x is
# /t/ID.
sub _requested_slug ($self) {
    return $self->stash('slug');
}

sub new_thread_form ($self) {
    my $categories = $self->gp_category_reader->list_categories(
        { viewer => $self->gp_forum_viewer } );

    my $payload = $self->gp_forum_view_model->new_thread_form(
        categories           => $categories,
        command_id           => $self->_new_command_id,
        csrf_token           => $self->csrf_token,
        errors               => {},
        selected_category_id => $self->param('category_id') || q{},
        values               => {},
    );

    return $self->render_payload(
        {
            controller => $self,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => 'forum/new_thread',
        }
    );
}

# A command id for each deleted thread the reader wrote, which only they may
# restore.
sub _restore_thread_command_ids ( $self, $threads, $user_id ) {
    if ( !$user_id ) {
        return {};
    }

    my %ids;
    for my $row ( @{ $threads->{items} || [] } ) {
        next if !$self->_column( $row, 'deleted_at' );

        my $author = $self->_column( $row, 'author_user_id' ) || q{};
        next if $author ne $user_id;

        my $thread_id = $self->_column( $row, 'thread_id' );
        next if !$thread_id;

        $ids{$thread_id} = $self->_new_command_id;
    }

    return \%ids;
}

1;

__END__

=head1 NAME

GPForum::Controller::Forum - Public forum read pages.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/categories')->to('Forum#categories');

=head1 DESCRIPTION

Renders public category, thread, and new-thread form pages.

A public page's cache key names the path its route writes for the request,
not the path as typed: C</c/ID/>, or C</c/ID> with a character written as
an escape, is C</c/ID> to the router and shares its entry.

=head1 SUBROUTINES/METHODS

=head2 categories

Renders the public category index, listing as many categories as
L<GPForum::Web::ForumAccess/category_list_limit> makes of C<limit>, which
the public cache key names.

=head2 category

Renders a category thread listing at C</c/ID>. An id written otherwise than
the database writes it (another case, braces, no hyphens) is answered with a
301 to C</c/ID>, the request's query kept, so it shares that page's public
cache entry instead of keying one of its own.

=head2 thread

Renders a visible thread page, at C</t/ID> or C</t/ID/SLUG>. A slug that is
not the thread's own, or an id written otherwise than the database writes it
(another case, braces, no hyphens), is answered with a 301 to C</t/ID/SLUG>
(the request's query kept), for a cached page as for one read from the
database; both URLs share one public cache entry, keyed by C</t/ID>.

=head2 new_thread_form

Renders the authenticated-or-anonymous new thread form.

=head1 DIAGNOSTICS

Missing resources render through the shared forum error helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses forum reader helpers configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Forum::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Write, community, and search actions live in sibling controllers.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
