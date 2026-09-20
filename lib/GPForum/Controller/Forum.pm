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

    my $user_id = $self->_current_user_id;
    my $threads = $self->gp_thread_reader->list_category_threads(
        {
            category_id    => $category_id,
            limit          => $self->list_page_limit,
            after          => $self->param('after'),
            viewer_user_id => $user_id,
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
            thread_id      => $self->param('thread_id'),
            limit          => $self->list_page_limit,
            after          => $self->param('after'),
            viewer_user_id => $user_id,
        }
    );

    if ( !$page->{ok} ) {
        return $self->_not_found('thread not found');
    }

    my $posts       = $page->{posts}{items};
    my $attachments = $self->attachments_for_posts($posts);

    my $payload = $self->gp_forum_view_model->thread_page(
        attachment_delete_command_ids =>
          $self->_attachment_delete_command_ids( $attachments, $user_id ),
        attachment_upload_command_ids =>
          $self->_edit_command_ids( $page, $user_id ),
        attachments_by_post => $attachments,
        engagement          => $self->gp_forum_view_model->engagement_summary(
            %{ $self->_community_command_ids($user_id) },
            bookmark_store     => $self->gp_bookmark_store,
            logger             => $self->app->log,
            subscription_store => $self->gp_subscription_store,
            thread             => $page->{thread},
            user_id            => $user_id,
        ),
        metadata_builder       => $self->gp_metadata_builder,
        page                   => $page,
        reply_command_id       => $user_id ? $self->_new_command_id : q{},
        edit_command_ids       => $self->_edit_command_ids( $page, $user_id ),
        delete_command_ids     => $self->_edit_command_ids( $page, $user_id ),
        report_command_ids     => $self->_edit_command_ids( $page, $user_id ),
        restore_command_ids    => $self->_edit_command_ids( $page, $user_id ),
        edit_thread_command_id =>
          $self->_thread_edit_command_id( $page, $user_id ),
        delete_thread_command_id =>
          $self->_thread_edit_command_id( $page, $user_id ),
        restore_thread_command_id =>
          $self->_thread_edit_command_id( $page, $user_id ),
        move_thread_command_id =>
          $self->_thread_edit_command_id( $page, $user_id ),
        categories     => $self->gp_category_reader->list_categories( {} ),
        viewer_user_id => $user_id,
        reading        => $self->gp_forum_view_model->reading_summary(
            posts           => $page->{posts}{items},
            read_command_id => $user_id ? $self->_new_command_id : q{},
            read_state      => $self->gp_thread_read_state,
            thread_id       => $self->param('thread_id'),
            user_id         => $user_id,
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

sub _edit_command_ids {
    my ( $self, $page, $user_id ) = @_;

    if ( !$user_id ) {
        return {};
    }

    my $items = $page->{posts}{items} || [];
    my %ids;
    for my $row ( @{$items} ) {
        $self->_store_edit_command_id( \%ids, $row, $user_id );
    }

    return \%ids;
}

sub _restore_thread_command_ids {
    my ( $self, $threads, $user_id ) = @_;

    if ( !$user_id ) {
        return {};
    }

    my $items = $threads->{items} || [];
    my %ids;
    for my $row ( @{$items} ) {
        $self->_store_restore_thread_id( \%ids, $row, $user_id );
    }

    return \%ids;
}

sub _store_restore_thread_id {
    my ( $self, $ids, $row, $user_id ) = @_;

    if ( !$self->_column( $row, 'deleted_at' ) ) {
        return;
    }

    my $author = $self->_column( $row, 'author_user_id' ) || q{};
    if ( $author ne $user_id ) {
        return;
    }

    my $thread_id = $self->_column( $row, 'thread_id' );
    if ( !$thread_id ) {
        return;
    }

    $ids->{$thread_id} = $self->_new_command_id;

    return;
}

sub _store_edit_command_id {
    my ( $self, $ids, $row, $user_id ) = @_;

    my $author = $self->_column( $row, 'author_user_id' );
    if ( !$author || $author ne $user_id ) {
        return;
    }

    my $post_id = $self->_column( $row, 'post_id' );
    if ( !$post_id ) {
        return;
    }

    $ids->{$post_id} = $self->_new_command_id;

    return;
}

sub _attachment_delete_command_ids {
    my ( $self, $by_post, $user_id ) = @_;

    if ( !$user_id ) {
        return {};
    }

    my %ids;
    for my $list ( values %{ $by_post || {} } ) {
        $self->_store_attachment_delete_ids( \%ids, $list );
    }

    return \%ids;
}

sub _store_attachment_delete_ids {
    my ( $self, $ids, $list ) = @_;

    for my $row ( @{ $list || [] } ) {
        $self->_store_one_attachment_delete_id( $ids, $row );
    }

    return;
}

sub _store_one_attachment_delete_id {
    my ( $self, $ids, $row ) = @_;

    my $attachment_id = $self->_column( $row, 'attachment_id' );
    if ( !$attachment_id ) {
        return;
    }

    $ids->{$attachment_id} = $self->_new_command_id;

    return;
}

sub _thread_edit_command_id {
    my ( $self, $page, $user_id ) = @_;

    if ( !$user_id ) {
        return q{};
    }

    my $author = $self->_column( $page->{thread}, 'author_user_id' );
    if ( !$author || $author ne $user_id ) {
        return q{};
    }

    return $self->_new_command_id;
}

sub _community_command_ids {
    my ( $self, $user_id ) = @_;

    if ( !$user_id ) {
        return {
            bookmark_command_id        => q{},
            bookmark_remove_command_id => q{},
            mute_command_id            => q{},
            subscribe_command_id       => q{},
            thread_report_command_id   => q{},
            unsubscribe_command_id     => q{},
        };
    }

    return {
        bookmark_command_id        => $self->_new_command_id,
        bookmark_remove_command_id => $self->_new_command_id,
        mute_command_id            => $self->_new_command_id,
        subscribe_command_id       => $self->_new_command_id,
        thread_report_command_id   => $self->_new_command_id,
        unsubscribe_command_id     => $self->_new_command_id,
    };
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
