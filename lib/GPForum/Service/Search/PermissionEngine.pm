# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Search::PermissionEngine;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Service::Forum::Viewer;
use GPForum::Service::Forum::Visibility;

our $VERSION = '0.001';

has schema => undef;

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
sub permits ( $self, $actor, $action, $resource, $options ) {    ## no critic (Subroutines::ProhibitManyArgs)
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
