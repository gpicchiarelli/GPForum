package GPForum::ViewModel::Forum::Presenter;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Base 'GPForum::ViewModel::Base';

our $VERSION = '0.001';

sub categories_page {
    my ( $self, %input ) = @_;

    return {
        categories => [ map { $self->category($_) } @{ $input{categories} } ],
    };
}

sub category_page {
    my ( $self, %input ) = @_;

    return {
        category => $self->category( $input{category} ),
        threads  =>
          [ map { $self->thread($_) } @{ $input{threads_page}{items} || [] } ],
        next_cursor => $input{threads_page}{next_cursor},
    };
}

sub thread_page {
    my ( $self, %input ) = @_;

    my $page             = $input{page};
    my $attachments      = _hash_or_empty( $input{attachments_by_post} );
    my $thread           = $self->thread( $page->{thread} );
    my $post_rows        = _array_or_empty( $page->{posts}{items} );
    my $engagement       = _thread_page_summary( $input{engagement} );
    my $reading          = _thread_page_summary( $input{reading} );
    my $reply_command_id = _string_or_empty( $input{reply_command_id} );
    my $posts = _thread_page_posts( $self, $post_rows, $attachments );

    return {
        engagement    => $engagement,
        next_cursor   => $page->{posts}{next_cursor},
        page_metadata => $self->thread_page_metadata(
            metadata_builder => $input{metadata_builder},
            posts            => $posts,
            thread           => $thread,
        ),
        posts            => $posts,
        reading          => $reading,
        reply_command_id => $reply_command_id,
        thread           => $thread,
    };
}

sub new_thread_form {
    my ( $self, %input ) = @_;

    my $errors = _hash_or_empty( $input{errors} );
    my $values = _hash_or_empty( $input{values} );
    my $selected_category_id =
      _new_thread_selected_category_id( \%input, $values );
    my %form_values = (
        %{$values},
        category_id => $selected_category_id,
        command_id  => _new_thread_command_id( \%input, $values ),
        visibility  => _new_thread_visibility($values),
    );
    my $fields = $self->form_fields(
        errors => $errors,
        values => \%form_values,
        specs  => [
            {
                id        => 'thread-category',
                label_key => 'search.category',
                name      => 'category_id',
                type      => 'select',
            },
            {
                id        => 'thread-title',
                label_key => 'forum.thread_title',
                name      => 'title',
                required  => 1,
                type      => 'text',
            },
            {
                id        => 'thread-body',
                label_key => 'forum.thread_body',
                name      => 'body_source',
                required  => 1,
                rows      => 10,
                type      => 'textarea',
            },
            {
                id        => 'thread-visibility',
                label_key => 'forum.visibility',
                name      => 'visibility',
                type      => 'select',
            },
        ],
    );

    return {
        categories => [
            map { $self->category($_) }
              @{ _array_or_empty( $input{categories} ) }
        ],
        csrf_token           => $input{csrf_token},
        command_id           => $form_values{command_id},
        error_fields         => $self->form_error_fields($fields),
        errors               => $errors,
        fields               => [qw(category_id title body_source visibility)],
        form_fields          => $fields,
        selected_category_id => $selected_category_id,
        ui                   => {
            described_by => $self->form_described_by(
                errors     => $errors,
                summary_id => 'thread-error-summary',
            ),
            heading_id => 'new-thread-heading',
            summary_id => 'thread-error-summary',
        },
        values => $values,
    };
}

sub _thread_page_posts {
    my ( $self, $post_rows, $attachments ) = @_;

    my @posts;
    for my $row ( @{$post_rows} ) {
        my $post = $self->post($row);
        $post->{attachments} = $attachments->{ $post->{post_id} } || [];
        push @posts, $post;
    }

    return \@posts;
}

sub _thread_page_summary {
    my ($value) = @_;

    return $value if ref $value eq 'HASH';

    return { authenticated => 0 };
}

sub _new_thread_selected_category_id {
    my ( $input, $values ) = @_;

    return $input->{selected_category_id}
      if defined $input->{selected_category_id}
      && length $input->{selected_category_id};

    return $values->{category_id}
      if defined $values->{category_id} && length $values->{category_id};

    return q{};
}

sub _new_thread_command_id {
    my ( $input, $values ) = @_;

    return $input->{command_id}
      if defined $input->{command_id} && length $input->{command_id};

    return $values->{command_id}
      if defined $values->{command_id} && length $values->{command_id};

    return q{};
}

sub _new_thread_visibility {
    my ($values) = @_;

    return $values->{visibility}
      if defined $values->{visibility} && length $values->{visibility};

    return 'public';
}

sub _string_or_empty {
    my ($value) = @_;

    return defined $value ? $value : q{};
}

sub _hash_or_empty {
    my ($value) = @_;

    return $value if ref $value eq 'HASH';

    return {};
}

sub _array_or_empty {
    my ($value) = @_;

    return $value if ref $value eq 'ARRAY';

    return [];
}

sub search_page {
    my ( $self, %input ) = @_;

    return {
        filters    => $input{filters}  || {},
        has_more   => $input{has_more} || 0,
        limit      => $input{limit},
        more_limit => $input{more_limit},
        query      => $self->string( $input{query} ),
        results    =>
          [ map { $self->search_result($_) } @{ $input{results} || [] } ],
        ( defined $input{status} ? ( status => $input{status} ) : () ),
    };
}

sub autocomplete_response {
    my ( $self, %input ) = @_;

    return {
        query       => $self->string( $input{query} ),
        suggestions => [
            map { $self->autocomplete_suggestion($_) }
              @{ $input{suggestions} || [] }
        ],
        ( defined $input{status} ? ( status => $input{status} ) : () ),
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

sub created_post_response {
    my ( $self, $stored ) = @_;

    return {
        post_id => $self->column( $stored->{post}, 'post_id' ),
        status  => 'created',
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

    return { authenticated => 0 }
      if !defined $input{user_id} || !length $input{user_id};

    return $input{read_state}
      ->summary_for_page( $input{user_id}, $input{thread_id},
        $input{posts} || [],
      );
}

sub engagement_summary {
    my ( $self, %input ) = @_;

    return { authenticated => 0 }
      if !defined $input{user_id} || !length $input{user_id};

    my $thread_id = $self->column( $input{thread}, 'thread_id' );
    my $summary   = eval {
        return {
            authenticated => 1,
            bookmark      => $input{bookmark_store}
              ->status_for_user_target( $input{user_id}, 'thread', $thread_id ),
            subscription => $input{subscription_store}
              ->status_for_user_target( $input{user_id}, 'thread', $thread_id ),
        };
    };

    if ($EVAL_ERROR) {
        $input{logger}->warn("engagement summary degraded: $EVAL_ERROR")
          if $input{logger};
        return {
            authenticated => 1,
            bookmark      => { bookmarked => 0 },
            status        => 'degraded',
            subscription  => { muted => 0, subscribed => 0 },
        };
    }

    return $summary;
}

sub thread_page_metadata {
    my ( $self, %input ) = @_;

    return {} if !$input{metadata_builder};

    return $input{metadata_builder}->thread_metadata(
        $input{thread},
        {
            safe_text => $input{posts}[0]{body} || q{},
        }
    );
}

sub category {
    my ( $self, $row ) = @_;

    return {
        category_id => $self->column( $row, 'category_id' ),
        description => $self->column( $row, 'description' ),
        position    => $self->column( $row, 'position' ),
        slug        => $self->column( $row, 'slug' ),
        title       => $self->column( $row, 'title' ),
        ui          => {
                heading_id => 'category-'
              . $self->string( $self->column( $row, 'category_id' ) )
              . '-heading',
        },
        visibility => $self->column( $row, 'visibility' ),
    };
}

sub thread {
    my ( $self, $row ) = @_;

    my $username = $self->column( $row, 'author_username' );

    return {
        author_display_name  => $self->column( $row, 'author_display_name' ),
        author_profile_label => $self->profile_label($username),
        author_user_id       => $self->column( $row, 'author_user_id' ),
        author_username      => $username,
        category_id          => $self->column( $row, 'category_id' ),
        last_activity_at     => $self->column( $row, 'last_activity_at' ),
        locked_at            => $self->column( $row, 'locked_at' ),
        moderation_state     => $self->column( $row, 'moderation_state' ),
        pinned               => $self->column( $row, 'pinned' ),
        slug                 => $self->column( $row, 'slug' ),
        thread_id            => $self->column( $row, 'thread_id' ),
        title                => $self->column( $row, 'title' ),
        ui                   => {
            heading_id => 'thread-'
              . $self->string( $self->column( $row, 'thread_id' ) )
              . '-heading',
            locked => $self->column( $row, 'locked_at' ) ? 1 : 0,
        },
        visibility => $self->column( $row, 'visibility' ),
    };
}

sub post {
    my ( $self, $row ) = @_;

    my $body_text = $self->column( $row, 'body' );
    if ( !defined $body_text ) {
        my $body = $self->related( $row, 'current_body' );
        $body_text = $self->column( $body, 'body_rendered_safe' ) if $body;
    }
    my $post_id  = $self->column( $row, 'post_id' );
    my $username = $self->column( $row, 'author_username' );

    return {
        author_display_name  => $self->column( $row, 'author_display_name' ),
        author_profile_label => $self->profile_label($username),
        author_user_id       => $self->column( $row, 'author_user_id' ),
        author_username      => $username,
        body                 => $body_text,
        moderation_state     => $self->column( $row, 'moderation_state' ),
        position             => $self->column( $row, 'position' ),
        post_id              => $post_id,
        thread_id            => $self->column( $row, 'thread_id' ),
        ui                   => {
            attachment_input_id => 'post-'
              . $self->string($post_id)
              . '-attachment',
            heading_id       => 'post-' . $self->string($post_id) . '-heading',
            permalink        => 'post-' . $self->string($post_id),
            report_reason_id => 'post-'
              . $self->string($post_id)
              . '-report-reason',
        },
        visibility => $self->column( $row, 'visibility' ),
    };
}

sub search_result {
    my ( $self, $row ) = @_;

    my $username = $self->column( $row, 'author_username' );

    return {
        author_display_name  => $self->column( $row, 'author_display_name' ),
        author_profile_label => $self->profile_label($username),
        author_user_id       => $self->column( $row, 'author_user_id' ),
        author_username      => $username,
        body                 => $self->column( $row, 'body' ),
        category_id          => $self->column( $row, 'category_id' ),
        entity_id            => $self->column( $row, 'entity_id' ),
        entity_type          => $self->column( $row, 'entity_type' ),
        indexed_at           => $self->column( $row, 'indexed_at' ),
        rank_score           => $self->column( $row, 'rank_score' ),
        snippet              => $self->column( $row, 'snippet' ),
        snippet_html         => $self->column( $row, 'snippet_html' ),
        source_created_at    => $self->column( $row, 'source_created_at' ),
        title                => $self->column( $row, 'title' ),
        ui                   => {
                heading_id => 'search-result-'
              . $self->string( $self->column( $row, 'entity_id' ) )
              . '-heading',
        },
        visibility => $self->column( $row, 'visibility' ),
    };
}

sub autocomplete_suggestion {
    my ( $self, $row ) = @_;

    my $username = $self->column( $row, 'author_username' );

    return {
        author_display_name  => $self->column( $row, 'author_display_name' ),
        author_profile_label => $self->profile_label($username),
        author_user_id       => $self->column( $row, 'author_user_id' ),
        author_username      => $username,
        category_id          => $self->column( $row, 'category_id' ),
        entity_id            => $self->column( $row, 'entity_id' ),
        entity_type          => $self->column( $row, 'entity_type' ),
        source_created_at    => $self->column( $row, 'source_created_at' ),
        title                => $self->column( $row, 'title' ),
        visibility           => $self->column( $row, 'visibility' ),
    };
}

sub report {
    my ( $self, $row ) = @_;

    return {
        created_at       => $self->column( $row, 'created_at' ),
        details          => $self->column( $row, 'details' ),
        reason           => $self->column( $row, 'reason' ),
        report_id        => $self->column( $row, 'report_id' ),
        reporter_user_id => $self->column( $row, 'reporter_user_id' ),
        status           => $self->column( $row, 'status' ),
        target_id        => $self->column( $row, 'target_id' ),
        target_type      => $self->column( $row, 'target_type' ),
    };
}

1;
