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
        threads     => [ map { $self->thread($_) } @{$items} ],
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

    if ( !$self->has_text( $input{user_id} ) ) {
        return { authenticated => 0 };
    }

    return $input{read_state}->summary_for_page( $input{user_id},
        $input{thread_id}, $input{posts} || [],
    );
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

    my $page  = $input->{page};
    my $posts = $self->_thread_page_posts(
        $self->array_or_empty( $page->{posts}{items} ),
        $self->hash_or_empty( $input->{attachments_by_post} ),
    );
    my $thread = $self->thread( $page->{thread} );

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
    my ( $self, $post_rows, $attachments ) = @_;

    my @posts;
    for my $row ( @{$post_rows} ) {
        push @posts, $self->_post_with_attachments( $row, $attachments );
    }

    return \@posts;
}

sub _post_with_attachments {
    my ( $self, $row, $attachments ) = @_;

    my $post = $self->post($row);
    $post->{attachments} = $attachments->{ $post->{post_id} } || [];

    return $post;
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
        subscription => $input->{subscription_store}
          ->status_for_user_target( $input->{user_id}, 'thread', $thread_id ),
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

=head2 created_post_response

Returns a created-post mutation payload.

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
