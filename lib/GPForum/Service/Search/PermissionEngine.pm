# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Search::PermissionEngine;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Service::Forum::Viewer;
use GPForum::Service::Forum::Visibility;

our $VERSION = '0.001';

# ADR 0102 for search. A document's own visibility (its thread's or post's)
# is fixed at index time; its category and space are joined live, so a
# category that turns private hides its documents at once, before any
# reindex. The rule is Forum::Visibility's, the same one every reader uses.
# Searcher joins category and space and selects their visibility.
sub search_condition ( $self, $actor ) {
    return {
        'category.deleted_at' => undef,
        %{ GPForum::Service::Forum::Visibility->readable_condition(
                _viewer($actor),
                {
                    category      => 'category.visibility',
                    category_id   => 'me.category_id',
                    space         => 'space.visibility',
                    space_id      => 'me.space_id',
                    thread        => 'me.visibility',
                    thread_author => 'me.author_user_id',
                }
            )
        },
    };
}

sub search_visibility_for ( $self, $actor, $options ) {
    return ('public') if _viewer($actor)->is_anonymous;
    return qw(public members private);
}

# Named `permits`, not `can` (ADR 0106). The same rule for one row, on the
# visibility columns Searcher selects; SQL has already applied it, so this
# only ever agrees -- it guards callers that bypass search_condition.
# actor, action, resource and options are the authorization question.
sub permits ( $self, $actor, $action, $resource, $options ) {
    return 0 if $action ne 'search.view';

    return GPForum::Service::Forum::Visibility->readable(
        _viewer($actor),
        {
            category_id         => $resource->{category_id},
            category_visibility => $resource->{category_visibility},
            space_id            => $resource->{space_id},
            space_visibility    => $resource->{space_visibility},
            thread_author       => $resource->{author_user_id},
            thread_visibility   => $resource->{visibility},
        }
    );
}

# The request's resolved viewer when the caller passes it; a bare user id
# reads as a non-member, and nothing as anonymous.
sub _viewer ($actor) {
    return $actor->{viewer} if ref $actor eq 'HASH' && $actor->{viewer};

    my $user_id = ref $actor eq 'HASH' ? $actor->{user_id} : $actor;

    return GPForum::Service::Forum::Viewer->from($user_id);
}

1;

__END__

=head1 NAME

GPForum::Service::Search::PermissionEngine - Which search documents a reader may see (ADR 0102).

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $engine = GPForum::Service::Search::PermissionEngine->new;
    my $where  = $engine->search_condition( { viewer => $viewer } );
    my $ok     = $engine->permits( { viewer => $viewer }, 'search.view',
        $row, {} );

=head1 DESCRIPTION

Search applies the same visibility rule as every other reader, from
L<GPForum::Service::Forum::Visibility>. A document's own visibility (its
thread's or post's) is fixed when it is indexed; its category and space are
joined live, so a category that turns private hides its documents at once,
before any reindex. L<GPForum::Service::Search::Searcher> puts
L</search_condition> in its query and checks each row it renders with
L</permits>.

The actor may be a hash reference holding a resolved C<viewer> (a
L<GPForum::Service::Forum::Viewer>), a hash reference or a bare value giving
a user id, a viewer object, or nothing. A bare user id reads as a signed-in
non-member and nothing as anonymous, so neither is ever wider than the truth.

=head1 SUBROUTINES/METHODS

=head2 search_condition

Takes the actor and returns a DBIx::Class condition: the category is not
deleted, and the reader may read the space, the category and the document,
over the columns C<space.visibility>, C<category.visibility>,
C<me.visibility>, C<me.space_id>, C<me.category_id> and
C<me.author_user_id>. The query must join C<category> and C<space>.

=head2 search_visibility_for

Takes the actor and an options hash that is not read, and returns the list
of document visibilities to filter on: C<public> for an anonymous reader,
otherwise C<public>, C<members> and C<private>. Searcher uses it only when
the engine has no L</search_condition>.

=head2 permits

Takes the actor, the action, a resource row and an options hash that is not
read. Returns 0 for any action other than C<search.view>; otherwise 1 or 0
from the visibility rule over the row's C<space_id>, C<space_visibility>,
C<category_id>, C<category_visibility>, C<visibility> and C<author_user_id>.
SQL has already applied the same rule, so for rows that came through
L</search_condition> it only ever agrees; it guards callers that bypass it.
Named C<permits>, not C<can> (ADR 0106).

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Forum::Visibility>,
L<GPForum::Service::Forum::Viewer>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

L</search_visibility_for> is coarser than the rule: it admits C<members>
and C<private> documents for every signed-in reader, and leaves the rest to
L</permits>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
