# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Search::DocumentBuilder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $DEFAULT_LANGUAGE         => 'simple';
const my $DEFAULT_PERMISSION_SCOPE => 'public';
const my $EMPTY_TEXT               => q{};

# The text-search configuration every document is built with. Searcher binds
# this same value into its tsquery, so the query and the stored vectors cannot
# disagree about how text was tokenised -- and because it arrives as a bind
# parameter rather than being read from the row, the planner can use the GIN
# index on search_vector.
sub search_config ($class) {
    return $DEFAULT_LANGUAGE;
}

sub build_thread ( $self, $thread ) {
    my $undefined;
    return $undefined if !_thread_is_visible($thread);

    return {
        entity_type        => 'thread',
        entity_id          => $thread->get_column('thread_id'),
        category_id        => $thread->get_column('category_id'),
        author_user_id     => $thread->get_column('author_user_id'),
        space_id           => _space_id_for_thread($thread),
        visibility         => $thread->get_column('visibility'),
        permission_scope   => _permission_scope($thread),
        visibility_version => $thread->get_column('visibility_version'),
        permission_version => $thread->get_column('permission_version'),
        language           => $DEFAULT_LANGUAGE,
        title              => $thread->get_column('title'),
        body               => $thread->get_column('title'),
        source_version     => $thread->get_column('version'),
        source_created_at  => $thread->get_column('created_at'),
    };
}

sub build_post ( $self, $post ) {
    my $undefined;
    return $undefined if !_post_is_visible($post);

    my $thread = $post->thread;
    return $undefined if !_thread_is_visible($thread);

    my $body = $post->current_body;

    return {
        entity_type        => 'post',
        entity_id          => $post->get_column('post_id'),
        category_id        => $thread->get_column('category_id'),
        author_user_id     => $post->get_column('author_user_id'),
        space_id           => _space_id_for_thread($thread),
        visibility         => $post->get_column('visibility'),
        permission_scope   => _permission_scope($post),
        visibility_version => $post->get_column('visibility_version'),
        permission_version => $post->get_column('permission_version'),
        language           => $DEFAULT_LANGUAGE,
        title              => $thread->get_column('title'),
        body               => _body_text($body),
        source_version     => $post->get_column('version'),
        source_created_at  => $post->get_column('created_at'),
    };
}

sub _thread_is_visible ($row) {
    my $undefined;
    return $undefined if !$row;
    return $undefined if defined $row->get_column('deleted_at');

    my $state = $row->get_column('moderation_state');
    return $state && ( $state eq 'visible' || $state eq 'locked' ) ? 1 : 0;
}

sub _post_is_visible ($row) {
    my $undefined;
    return $undefined if !$row;
    return $undefined if defined $row->get_column('deleted_at');

    return $row->get_column('moderation_state') eq 'visible' ? 1 : 0;
}

sub _permission_scope ($row) {
    return $row->get_column('visibility') || $DEFAULT_PERMISSION_SCOPE;
}

sub _space_id_for_thread ($thread) {
    my $undefined;
    return $thread->get_column('space_id')
      if $thread->can('has_column')
      && $thread->has_column('space_id');

    return $undefined if !$thread->can('category');

    my $category = $thread->category;
    return $undefined if !$category;

    return $category->get_column('space_id');
}

sub _body_text ($body) {
    return $EMPTY_TEXT if !$body;
    return
         $body->get_column('body_rendered_safe')
      || $body->get_column('body_source')
      || $EMPTY_TEXT;
}

1;

__END__

=head1 NAME

GPForum::Service::Search::DocumentBuilder - The search document of a thread or a post.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $builder  = GPForum::Service::Search::DocumentBuilder->new;
    my $document = $builder->build_post($post_row);
    # undef: the post, or its thread, is not searchable; remove its document

    my $config = GPForum::Service::Search::DocumentBuilder->search_config;

=head1 DESCRIPTION

Turns a thread or post row into the fields of its C<search_documents> row,
for L<GPForum::Service::Search::Indexer>. It reads rows and returns a hash;
it writes nothing.

Only what a reader could find is built. A thread is searchable while it is
not deleted and its moderation state is C<visible> or C<locked>; a post
while it is not deleted, its state is C<visible> and its thread is
searchable. For anything else the builder returns undef, and the indexer
removes the document.

A thread's document has its title as both title and body. A post's has its
thread's title and its current body: the sanitized rendering when there is
one, else the source text. Both carry the thread's category and space
(the thread's own C<space_id> column when it has one, else its
category's), the row's author and visibility, its visibility and
permission versions, its version and creation time, and a
C<permission_scope> that is the row's visibility or C<public>.

=head1 SUBROUTINES/METHODS

=head2 search_config

A class method. Returns the text-search configuration every document is
built with, C<simple>. L<GPForum::Service::Search::Searcher> binds the same
value into its query, so the query and the stored vectors cannot disagree
about how text was tokenised, and as a bind parameter rather than a column
of the row it leaves the planner free to use the GIN index on
C<search_vector>.

=head2 build_thread

Takes a C<Thread> row (or undef). Returns undef when the thread is not
searchable; otherwise a hash reference with C<entity_type> C<thread>,
C<entity_id>, C<category_id>, C<author_user_id>, C<space_id>,
C<visibility>, C<permission_scope>, C<visibility_version>,
C<permission_version>, C<language>, C<title>, C<body>, C<source_version>
and C<source_created_at>.

=head2 build_post

Takes a C<Post> row (or undef). Returns undef when the post or its thread
is not searchable; otherwise a hash reference with the same fields as
C<build_thread>, C<entity_type> C<post>, the post's own id, author,
visibility, versions and creation time, and its thread's category, space
and title.

=head1 DIAGNOSTICS

None of its own. Reading a relation (the thread, the body, the category)
dies when the database does.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
