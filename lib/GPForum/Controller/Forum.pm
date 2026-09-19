package GPForum::Controller::Forum;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'GPForum::Controller::Forum::Base';

our $VERSION = '0.001';

const my $HTTP_OK => 200;

sub categories {
    my ($self) = @_;

    my $categories =
      $self->gp_category_reader->list_categories(
        { limit => $self->param('limit') } );
    my $payload =
      $self->gp_forum_view_model->categories_page( categories => $categories );

    return $self->render_payload(
        {
            cache_options =>
              $self->public_cache_options( 'categories', ['forum:categories'] ),
            controller => $self,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => 'forum/categories',
        }
    );
}

sub category {
    my ($self) = @_;

    my $category_id = $self->param('category_id');
    my $category    = $self->gp_category_reader->find_category($category_id);

    if ( !$category ) {
        return $self->_not_found('category not found');
    }

    my $threads = $self->gp_thread_reader->list_category_threads(
        {
            category_id => $category_id,
            limit       => $self->list_page_limit,
            after       => $self->param('after'),
        }
    );

    my $payload = $self->gp_forum_view_model->category_page(
        category     => $category,
        threads_page => $threads,
    );

    return $self->render_payload(
        {
            cache_options => $self->public_cache_options(
                'category',
                [ 'forum:categories', "forum:category:$category_id" ]
            ),
            controller => $self,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => 'forum/category',
        }
    );
}

sub thread {
    my ($self) = @_;

    my $user_id = $self->_current_user_id;
    my $page    = $self->gp_thread_detail_reader->thread_page(
        {
            thread_id => $self->param('thread_id'),
            limit     => $self->list_page_limit,
            after     => $self->param('after'),
        }
    );

    if ( !$page->{ok} ) {
        return $self->_not_found('thread not found');
    }

    my $payload = $self->gp_forum_view_model->thread_page(
        attachments_by_post =>
          $self->attachments_for_posts( $page->{posts}{items} ),
        engagement => $self->gp_forum_view_model->engagement_summary(
            bookmark_store     => $self->gp_bookmark_store,
            logger             => $self->app->log,
            subscription_store => $self->gp_subscription_store,
            thread             => $page->{thread},
            user_id            => $user_id,
        ),
        metadata_builder => $self->gp_metadata_builder,
        page             => $page,
        reply_command_id => $user_id ? $self->_new_command_id : q{},
        reading          => $self->gp_forum_view_model->reading_summary(
            posts      => $page->{posts}{items},
            read_state => $self->gp_thread_read_state,
            thread_id  => $self->param('thread_id'),
            user_id    => $user_id,
        ),
    );

    return $self->render_payload(
        {
            cache_options => $self->public_cache_options(
                'thread', [ 'forum:thread:' . $self->param('thread_id') ]
            ),
            controller => $self,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => 'forum/thread',
        }
    );
}

sub new_thread_form {
    my ($self) = @_;

    my $categories = $self->gp_category_reader->list_categories( {} );

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

=head1 SUBROUTINES/METHODS

=head2 categories

Renders the public category index.

=head2 category

Renders a category thread listing.

=head2 thread

Renders a visible thread page.

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
