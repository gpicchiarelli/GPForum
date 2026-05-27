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

    my $page        = $input{page};
    my $attachments = $input{attachments_by_post} || {};
    my $thread      = $self->thread( $page->{thread} );
    my @posts       = map {
        my $post = $self->post($_);
        $post->{attachments} = $attachments->{ $post->{post_id} } || [];
        $post;
    } @{ $page->{posts}{items} || [] };

    return {
        engagement    => $input{engagement} || { authenticated => 0 },
        next_cursor   => $page->{posts}{next_cursor},
        page_metadata => $self->thread_page_metadata(
            metadata_builder => $input{metadata_builder},
            posts            => \@posts,
            thread           => $thread,
        ),
        posts   => \@posts,
        reading => $input{reading} || { authenticated => 0 },
        thread  => $thread,
    };
}

sub new_thread_form {
    my ( $self, %input ) = @_;

    my $values = $input{values} || {};

    return {
        categories =>
          [ map { $self->category($_) } @{ $input{categories} || [] } ],
        csrf_token           => $input{csrf_token},
        errors               => $input{errors} || {},
        fields               => [qw(category_id title body_source visibility)],
        selected_category_id => $input{selected_category_id}
          || $values->{category_id}
          || q{},
        ui => {
            described_by => 'thread-error-summary',
            heading_id   => 'new-thread-heading',
        },
        values => $values,
    };
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
