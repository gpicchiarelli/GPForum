package GPForum::ViewModel::Forum::Page;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Base 'GPForum::ViewModel::Forum::Rows';

our $VERSION = '0.001';

sub categories_page {
    my ( $self, %input ) = @_;

    return {
        categories => [ map { $self->category($_) } @{ $input{categories} } ],
    };
}

sub category_page {
    my ( $self, %input ) = @_;

    my $items = $self->array_or_empty( $input{threads_page}{items} );

    return {
        category    => $self->category( $input{category} ),
        next_cursor => $input{threads_page}{next_cursor},
        threads => [ map { $self->_category_thread( $_, \%input ) } @{$items} ],
    };
}

sub thread_page {
    my ( $self, %input ) = @_;

    my $parts = $self->_thread_page_parts( \%input );

    return {
        %{$parts},
        page_metadata => $self->thread_page_metadata(
            metadata_builder => $input{metadata_builder},
            posts            => $parts->{posts},
            thread           => $parts->{thread},
        ),
    };
}

sub search_page {
    my ( $self, %input ) = @_;

    my $results = $self->array_or_empty( $input{results} );

    return {
        filters    => $input{filters}  || {},
        has_more   => $input{has_more} || 0,
        limit      => $input{limit},
        more_limit => $input{more_limit},
        query      => $self->string( $input{query} ),
        results    => [ map { $self->search_result($_) } @{$results} ],
        $self->_optional_status( $input{status} ),
    };
}

sub autocomplete_response {
    my ( $self, %input ) = @_;

    my $suggestions = $self->array_or_empty( $input{suggestions} );

    return {
        query       => $self->string( $input{query} ),
        suggestions =>
          [ map { $self->autocomplete_suggestion($_) } @{$suggestions} ],
        $self->_optional_status( $input{status} ),
    };
}

sub report_response {
    my ( $self, $report ) = @_;

    return {
        report => $self->report($report),
        status => 'reported',
    };
}

sub created_thread_response {
    my ( $self, $stored ) = @_;

    return {
        status    => 'created',
        thread_id => $self->column( $stored->{thread}, 'thread_id' ),
    };
}

sub updated_thread_response {
    my ( $self, $stored ) = @_;

    return {
        slug      => $self->column( $stored->{thread}, 'slug' ),
        status    => 'updated',
        thread_id => $self->column( $stored->{thread}, 'thread_id' ),
        title     => $self->column( $stored->{thread}, 'title' ),
    };
}

sub deleted_thread_response {
    my ( $self, $stored ) = @_;

    return {
        status    => 'deleted',
        thread_id => $self->column( $stored->{thread}, 'thread_id' ),
    };
}

sub restored_thread_response {
    my ( $self, $stored ) = @_;

    return {
        status    => 'restored',
        thread_id => $self->column( $stored->{thread}, 'thread_id' ),
    };
}

sub moved_thread_response {
    my ( $self, $stored ) = @_;

    return {
        category_id => $self->column( $stored->{thread}, 'category_id' ),
        status      => 'moved',
        thread_id   => $self->column( $stored->{thread}, 'thread_id' ),
    };
}

sub created_post_response {
    my ( $self, $stored ) = @_;

    return {
        post_id => $self->column( $stored->{post}, 'post_id' ),
        status  => 'created',
    };
}

sub updated_post_response {
    my ( $self, $stored ) = @_;

    return {
        post_id   => $self->column( $stored->{post}, 'post_id' ),
        status    => 'updated',
        thread_id => $self->column( $stored->{post}, 'thread_id' ),
    };
}

sub deleted_post_response {
    my ( $self, $stored ) = @_;

    return {
        post_id   => $self->column( $stored->{post}, 'post_id' ),
        status    => 'deleted',
        thread_id => $self->column( $stored->{post}, 'thread_id' ),
    };
}

sub restored_post_response {
    my ( $self, $stored ) = @_;

    return {
        post_id   => $self->column( $stored->{post}, 'post_id' ),
        status    => 'restored',
        thread_id => $self->column( $stored->{post}, 'thread_id' ),
    };
}

sub read_marker_response {
    my ( $self, $marked ) = @_;

    return {
        read_state => $marked->{read_state},
        status     => 'ok',
    };
}

sub reading_summary {
    my ( $self, %input ) = @_;

    if ( !$self->has_text( $input{user_id} ) ) {
        return { authenticated => 0 };
    }

    return $self->_reading_for_user( \%input );
}

sub _reading_for_user {
    my ( $self, $input ) = @_;

    my $summary =
      $input->{read_state}->summary_for_page( $input->{user_id},
        $input->{thread_id}, $input->{posts} || [],
      );
    $summary->{read_command_id} =
      $self->string_or_empty( $input->{read_command_id} );

    return $summary;
}

sub engagement_summary {
    my ( $self, %input ) = @_;

    if ( !$self->has_text( $input{user_id} ) ) {
        return { authenticated => 0 };
    }

    return $self->_engagement_for_user( \%input );
}

sub thread_page_metadata {
    my ( $self, %input ) = @_;

    if ( !$input{metadata_builder} ) {
        return {};
    }

    return $input{metadata_builder}->thread_metadata( $input{thread},
        { safe_text => $input{posts}[0]{body} || q{}, },
    );
}

sub _thread_page_parts {
    my ( $self, $input ) = @_;

    my $page   = $input->{page};
    my $thread = $self->thread( $page->{thread} );
    my $posts  = $self->_thread_page_posts(
        $self->array_or_empty( $page->{posts}{items} ),
        {
            attachments =>
              $self->hash_or_empty( $input->{attachments_by_post} ),
            attachment_delete_command_ids =>
              $self->hash_or_empty( $input->{attachment_delete_command_ids} ),
            attachment_upload_command_ids =>
              $self->hash_or_empty( $input->{attachment_upload_command_ids} ),
            delete_command_ids =>
              $self->hash_or_empty( $input->{delete_command_ids} ),
            edit_command_ids =>
              $self->hash_or_empty( $input->{edit_command_ids} ),
            restore_command_ids =>
              $self->hash_or_empty( $input->{restore_command_ids} ),
            report_command_ids =>
              $self->hash_or_empty( $input->{report_command_ids} ),
            thread         => $thread,
            viewer_user_id => $input->{viewer_user_id},
        },
    );
    $self->_apply_thread_edit_state( $thread, $input );
    $self->_apply_thread_restore_state( $thread, $input );

    return {
        engagement       => $self->_summary_hash( $input->{engagement} ),
        next_cursor      => $page->{posts}{next_cursor},
        posts            => $posts,
        reading          => $self->_summary_hash( $input->{reading} ),
        reply_command_id =>
          $self->string_or_empty( $input->{reply_command_id} ),
        thread => $thread,
    };
}

sub _thread_page_posts {
    my ( $self, $post_rows, $context ) = @_;

    my @posts;
    for my $row ( @{$post_rows} ) {
        push @posts, $self->_post_with_attachments( $row, $context );
    }

    return \@posts;
}

sub _post_with_attachments {
    my ( $self, $row, $context ) = @_;

    my $post = $self->post($row);
    $post->{attachments} = $self->_attachments_for_post( $post, $context );
    $self->_apply_edit_state( $post, $row, $context );
    $self->_apply_restore_state( $post, $context );
    $self->_apply_report_state( $post, $context );

    return $post;
}

sub _category_thread {
    my ( $self, $row, $input ) = @_;

    my $thread = $self->thread($row);
    $self->_apply_thread_restore_state( $thread, $input );

    return $thread;
}

sub _apply_thread_restore_state {
    my ( $self, $thread, $input ) = @_;

    return if !$self->_thread_is_restorable( $thread, $input );

    $thread->{can_restore_thread} = 1;
    $thread->{restore_thread_command_id} =
      $self->_restore_thread_command_id( $thread, $input );

    return;
}

sub _restore_thread_command_id {
    my ( $self, $thread, $input ) = @_;

    my $ids = $self->hash_or_empty( $input->{restore_thread_command_ids} );

    return $self->string_or_empty( $ids->{ $thread->{thread_id} }
          || $input->{restore_thread_command_id} );
}

sub _apply_thread_edit_state {
    my ( $self, $thread, $input ) = @_;

    if ( !$self->_thread_is_editable( $thread, $input ) ) {
        return;
    }

    $thread->{can_edit_thread}   = 1;
    $thread->{can_delete_thread} = 1;
    $thread->{can_move_thread}   = 1;
    $thread->{edit_thread_command_id} =
      $self->string_or_empty( $input->{edit_thread_command_id} );
    $thread->{delete_thread_command_id} =
      $self->string_or_empty( $input->{delete_thread_command_id} );
    $thread->{move_thread_command_id} =
      $self->string_or_empty( $input->{move_thread_command_id} );
    $thread->{move_categories} = $self->_move_categories($input);

    return;
}

sub _thread_is_editable {
    my ( $self, $thread, $input ) = @_;

    return 0 if $self->has_text( $thread->{deleted_at} );

    return $self->_author_thread_write( $thread, $input );
}

sub _thread_is_restorable {
    my ( $self, $thread, $input ) = @_;

    return 0 if !$self->has_text( $thread->{deleted_at} );

    return $self->_author_thread_write( $thread, $input );
}

sub _author_thread_write {
    my ( $self, $thread, $input ) = @_;

    my $viewer = $input->{viewer_user_id};
    if ( !$self->has_text($viewer) ) {
        return 0;
    }
    if ( $thread->{locked_at} ) {
        return 0;
    }

    my $author = $thread->{author_user_id} || q{};

    return $author eq $viewer ? 1 : 0;
}

sub _move_categories {
    my ( $self, $input ) = @_;

    my $categories = $self->array_or_empty( $input->{categories} );

    return [ map { $self->category($_) } @{$categories} ];
}

sub _apply_report_state {
    my ( $self, $post, $context ) = @_;

    $post->{report_command_id} =
      $self->string_or_empty(
        $context->{report_command_ids}{ $post->{post_id} } );

    return;
}

sub _apply_edit_state {
    my ( $self, $post, $row, $context ) = @_;

    return if !$self->_post_is_editable( $post, $context );

    $post->{body_source} = $self->_edit_body_source($row);
    $post->{can_edit}    = 1;
    $post->{can_delete}  = 1;
    $post->{delete_command_id} =
      $self->string_or_empty(
        $context->{delete_command_ids}{ $post->{post_id} } );
    $post->{edit_command_id} =
      $self->string_or_empty(
        $context->{edit_command_ids}{ $post->{post_id} } );
    $post->{upload_command_id} =
      $self->string_or_empty(
        $context->{attachment_upload_command_ids}{ $post->{post_id} } );

    return;
}

sub _attachments_for_post {
    my ( $self, $post, $context ) = @_;

    my $rows = $context->{attachments}{ $post->{post_id} } || [];
    my @attachments;
    for my $row ( @{$rows} ) {
        push @attachments, $self->_attachment_with_command( $row, $context );
    }

    return \@attachments;
}

sub _attachment_with_command {
    my ( $self, $row, $context ) = @_;

    my %attachment = %{$row};
    $attachment{delete_command_id} = $self->string_or_empty(
        $context->{attachment_delete_command_ids}{ $attachment{attachment_id} }
    );

    return \%attachment;
}

sub _apply_restore_state {
    my ( $self, $post, $context ) = @_;

    return if !$self->_post_is_restorable( $post, $context );

    $post->{can_restore} = 1;
    $post->{restore_command_id} =
      $self->string_or_empty(
        $context->{restore_command_ids}{ $post->{post_id} } );

    return;
}

sub _edit_body_source {
    my ( $self, $row ) = @_;

    my $source = $self->_body_source($row);
    if ( $self->has_text($source) ) {
        return $source;
    }

    return $self->string_or_empty( $self->column( $row, 'body' ) );
}

sub _post_is_editable {
    my ( $self, $post, $context ) = @_;

    return 0 if !$self->_author_write_context($context);
    return 0 if $self->has_text( $post->{deleted_at} );

    return $self->_same_viewer( $post, $context );
}

sub _post_is_restorable {
    my ( $self, $post, $context ) = @_;

    return 0 if !$self->_author_write_context($context);
    return 0 if !$self->has_text( $post->{deleted_at} );

    return $self->_same_viewer( $post, $context );
}

sub _author_write_context {
    my ( $self, $context ) = @_;

    return 0 if !$self->has_text( $context->{viewer_user_id} );
    return 0 if $context->{thread}{locked_at};

    return 1;
}

sub _same_viewer {
    my ( $self, $post, $context ) = @_;

    my $author = $post->{author_user_id} || q{};

    return $author eq ( $context->{viewer_user_id} || q{} ) ? 1 : 0;
}

sub _summary_hash {
    my ( undef, $value ) = @_;

    if ( ref $value eq 'HASH' ) {
        return $value;
    }

    return { authenticated => 0 };
}

sub _optional_status {
    my ( undef, $status ) = @_;

    if ( defined $status ) {
        return ( status => $status );
    }

    return;
}

sub _engagement_for_user {
    my ( $self, $input ) = @_;

    my $summary = eval { return $self->_engagement_lookup($input); };
    if ($EVAL_ERROR) {
        $self->_warn_engagement( $input, $EVAL_ERROR );
        return $self->_degraded_engagement;
    }

    return $summary;
}

sub _engagement_lookup {
    my ( $self, $input ) = @_;

    my $thread_id = $self->column( $input->{thread}, 'thread_id' );

    return {
        authenticated => 1,
        bookmark      => $input->{bookmark_store}
          ->status_for_user_target( $input->{user_id}, 'thread', $thread_id ),
        bookmark_command_id =>
          $self->string_or_empty( $input->{bookmark_command_id} ),
        bookmark_remove_command_id =>
          $self->string_or_empty( $input->{bookmark_remove_command_id} ),
        mute_command_id => $self->string_or_empty( $input->{mute_command_id} ),
        subscribe_command_id =>
          $self->string_or_empty( $input->{subscribe_command_id} ),
        subscription => $input->{subscription_store}
          ->status_for_user_target( $input->{user_id}, 'thread', $thread_id ),
        thread_report_command_id =>
          $self->string_or_empty( $input->{thread_report_command_id} ),
        unsubscribe_command_id =>
          $self->string_or_empty( $input->{unsubscribe_command_id} ),
    };
}

sub _warn_engagement {
    my ( undef, $input, $error ) = @_;

    if ( $input->{logger} ) {
        $input->{logger}->warn("engagement summary degraded: $error");
    }

    return;
}

sub _degraded_engagement {
    return {
        authenticated => 1,
        bookmark      => { bookmarked => 0 },
        status        => 'degraded',
        subscription  => { muted => 0, subscribed => 0 },
    };
}

1;

__END__

=head1 NAME

GPForum::ViewModel::Forum::Page - Forum page view models.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $page = $pages->thread_page(%input);

=head1 DESCRIPTION

Assembles category, thread, search, and mutation page payloads from row
view models. New-thread form state stays on
L<GPForum::ViewModel::Forum::Form>.
L<GPForum::ViewModel::Forum::Presenter> remains the public facade.

=head1 SUBROUTINES/METHODS

=head2 categories_page

Returns the category index payload.

=head2 category_page

Returns a category thread-list payload.

=head2 thread_page

Returns a thread page with posts, attachments, and metadata.

=head2 search_page

Returns a search results payload.

=head2 autocomplete_response

Returns autocomplete suggestions.

=head2 report_response

Returns a created-report payload.

=head2 created_thread_response

Returns a created-thread mutation payload.

=head2 updated_thread_response

Returns an updated-thread mutation payload.

=head2 deleted_thread_response

Returns a deleted-thread mutation payload.

=head2 restored_thread_response

Returns a restored-thread mutation payload.

=head2 moved_thread_response

Returns a moved-thread mutation payload.

=head2 created_post_response

Returns a created-post mutation payload.

=head2 updated_post_response

Returns an updated-post mutation payload.

=head2 deleted_post_response

Returns a deleted-post mutation payload.

=head2 read_marker_response

Returns a read-marker mutation payload.

=head2 reading_summary

Returns anonymous or per-user reading state.

=head2 engagement_summary

Returns bookmark and subscription state, or a degraded payload.

=head2 thread_page_metadata

Delegates document metadata when a builder is supplied.

=head1 DIAGNOSTICS

Engagement lookup failures log a warning when a logger is present and return
a degraded authenticated payload.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<GPForum::ViewModel::Forum::Rows>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Attachment lists are keyed by post id from the store, not loaded here.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
