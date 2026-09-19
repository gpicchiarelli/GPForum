package GPForum::ViewModel::Forum::Rows;

use strict;
use warnings;

use GPForum::Service::Forum::BodyRenderer;
use Mojo::Base 'GPForum::ViewModel::Base';

our $VERSION = '0.001';

has body_renderer => sub { return GPForum::Service::Forum::BodyRenderer->new; };

sub category {
    my ( $self, $row ) = @_;

    my $category_id = $self->column( $row, 'category_id' );

    return {
        category_id => $category_id,
        description => $self->column( $row, 'description' ),
        position    => $self->column( $row, 'position' ),
        slug        => $self->column( $row, 'slug' ),
        title       => $self->column( $row, 'title' ),
        ui          => {
                heading_id => 'category-'
              . $self->string($category_id)
              . '-heading',
        },
        visibility => $self->column( $row, 'visibility' ),
    };
}

sub thread {
    my ( $self, $row ) = @_;

    my $username  = $self->column( $row, 'author_username' );
    my $thread_id = $self->column( $row, 'thread_id' );
    my $locked_at = $self->column( $row, 'locked_at' );

    return {
        author_display_name  => $self->column( $row, 'author_display_name' ),
        author_profile_label => $self->profile_label($username),
        author_user_id       => $self->column( $row, 'author_user_id' ),
        author_username      => $username,
        category_id          => $self->column( $row, 'category_id' ),
        last_activity_at     => $self->column( $row, 'last_activity_at' ),
        locked_at            => $locked_at,
        moderation_state     => $self->column( $row, 'moderation_state' ),
        pinned               => $self->column( $row, 'pinned' ),
        slug                 => $self->column( $row, 'slug' ),
        thread_id            => $thread_id,
        title                => $self->column( $row, 'title' ),
        ui                   => {
            heading_id => 'thread-' . $self->string($thread_id) . '-heading',
            locked     => $locked_at ? 1 : 0,
        },
        visibility => $self->column( $row, 'visibility' ),
    };
}

sub post {
    my ( $self, $row ) = @_;

    my $post_id  = $self->column( $row, 'post_id' );
    my $username = $self->column( $row, 'author_username' );

    return {
        author_display_name  => $self->column( $row, 'author_display_name' ),
        author_profile_label => $self->profile_label($username),
        author_user_id       => $self->column( $row, 'author_user_id' ),
        author_username      => $username,
        body                 => $self->_post_body($row),
        moderation_state     => $self->column( $row, 'moderation_state' ),
        position             => $self->column( $row, 'position' ),
        post_id              => $post_id,
        thread_id            => $self->column( $row, 'thread_id' ),
        ui                   => $self->_post_ui($post_id),
        visibility           => $self->column( $row, 'visibility' ),
    };
}

sub search_result {
    my ( $self, $row ) = @_;

    my $username  = $self->column( $row, 'author_username' );
    my $entity_id = $self->column( $row, 'entity_id' );

    return {
        author_display_name  => $self->column( $row, 'author_display_name' ),
        author_profile_label => $self->profile_label($username),
        author_user_id       => $self->column( $row, 'author_user_id' ),
        author_username      => $username,
        body                 => $self->column( $row, 'body' ),
        category_id          => $self->column( $row, 'category_id' ),
        entity_id            => $entity_id,
        entity_type          => $self->column( $row, 'entity_type' ),
        indexed_at           => $self->column( $row, 'indexed_at' ),
        rank_score           => $self->column( $row, 'rank_score' ),
        snippet              => $self->column( $row, 'snippet' ),
        snippet_html         => $self->column( $row, 'snippet_html' ),
        source_created_at    => $self->column( $row, 'source_created_at' ),
        title                => $self->column( $row, 'title' ),
        ui                   => {
                heading_id => 'search-result-'
              . $self->string($entity_id)
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

sub has_text {
    my ( undef, $value ) = @_;

    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

sub hash_or_empty {
    my ( undef, $value ) = @_;

    if ( ref $value eq 'HASH' ) {
        return $value;
    }

    return {};
}

sub array_or_empty {
    my ( undef, $value ) = @_;

    if ( ref $value eq 'ARRAY' ) {
        return $value;
    }

    return [];
}

sub string_or_empty {
    my ( undef, $value ) = @_;

    if ( defined $value ) {
        return $value;
    }

    return q{};
}

sub _post_body {
    my ( $self, $row ) = @_;

    my $source = $self->_body_source($row);
    if ( defined $source && length $source ) {
        return $self->body_renderer->render_safe($source);
    }

    return $self->_stored_safe_body($row);
}

sub _body_source {
    my ( $self, $row ) = @_;

    my $direct = $self->column( $row, 'body_source' );
    if ( defined $direct && length $direct ) {
        return $direct;
    }

    return $self->_related_source($row);
}

sub _related_source {
    my ( $self, $row ) = @_;

    my $body = $self->related( $row, 'current_body' );
    if ( !$body ) {
        return;
    }

    return $self->column( $body, 'body_source' );
}

sub _stored_safe_body {
    my ( $self, $row ) = @_;

    my $body_text = $self->column( $row, 'body' );
    if ( defined $body_text ) {
        return $body_text;
    }

    return $self->_related_body($row);
}

sub _related_body {
    my ( $self, $row ) = @_;

    my $body = $self->related( $row, 'current_body' );
    if ( !$body ) {
        return;
    }

    return $self->column( $body, 'body_rendered_safe' );
}

sub _post_ui {
    my ( $self, $post_id ) = @_;

    my $token = $self->string($post_id);

    return {
        attachment_input_id => 'post-' . $token . '-attachment',
        heading_id          => 'post-' . $token . '-heading',
        permalink           => 'post-' . $token,
        report_reason_id    => 'post-' . $token . '-report-reason',
    };
}

1;

__END__

=head1 NAME

GPForum::ViewModel::Forum::Rows - Forum row view models.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $thread = $rows->thread($row);

=head1 DESCRIPTION

Shapes category, thread, post, search, autocomplete, and report hashes.
Page assembly and new-thread form state stay on dedicated forum view-model
helpers. L<GPForum::ViewModel::Forum::Presenter> remains the public facade.

=head1 SUBROUTINES/METHODS

=head2 category

Returns a category payload with heading metadata.

=head2 thread

Returns a thread payload with lock and heading metadata.

=head2 post

Returns a post payload, including a safe rendered body when present.

=head2 search_result

Returns a search-hit payload.

=head2 autocomplete_suggestion

Returns a suggestion without body text.

=head2 report

Returns a report payload.

=head2 has_text

True when the value is defined and non-empty.

=head2 hash_or_empty

Returns the hash or an empty hash.

=head2 array_or_empty

Returns the array or an empty array.

=head2 string_or_empty

Returns the string or an empty string.

=head1 DIAGNOSTICS

Missing rows yield undef columns through L<GPForum::ViewModel::Base>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<GPForum::ViewModel::Base> and
L<GPForum::Service::Forum::BodyRenderer>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Post bodies render markdown source through
L<GPForum::Service::Forum::BodyRenderer> when C<body_source> is present.
Otherwise they pass through already-sanitized C<body_rendered_safe> HTML.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
