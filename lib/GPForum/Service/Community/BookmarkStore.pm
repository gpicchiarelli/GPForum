# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Community::BookmarkStore;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::Keyset;
use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Forum::PageWindow;
use GPForum::Infrastructure::Id;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT     => 50;
const my $ID_CONSTRAINT     => 'bookmarks_pkey';
const my $TARGET_CONSTRAINT => 'bookmarks_user_target_key';
const my @CURSOR_COLUMNS    => qw(created_at bookmark_id);

has clock       => sub { return GPForum::Service::Clock->new; };
has id_service  => sub { return GPForum::Infrastructure::Id->new; };
has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

# ADR 0102: only rows whose post or thread the reader can still read, judged
# in the query before LIMIT. A bookmark kept pointing at a thread after its
# category turned private, showing its title to someone who lost access.
has readability => undef;

sub save_bookmark ( $self, $input ) {
    my $existing =
      $self->find_for_user_target( $input->{user_id}, $input->{target_type},
        $input->{target_id}, );

    if ($existing) {
        return $self->_restore_bookmark( $existing, $input );
    }

    return $self->_insert_or_restore($input);
}

sub _insert_or_restore ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->create_bookmark($input); },
      );
    if ($created) {
        return $created;
    }

    return $self->_restore_after_conflict( $input, $error );
}

sub _restore_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_bookmark_after_unique( $input, $error );
}

sub _bookmark_after_unique ( $self, $input, $error ) {
    if ( _bookmark_id_conflict($error) ) {
        return $self->_bookmark_after_id_conflict($input);
    }
    if ( _bookmark_target_conflict($error) ) {
        return $self->_reuse_bookmark_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _bookmark_after_id_conflict ( $self, $input ) {
    my $existing = $self->_existing_bookmark($input);
    if ($existing) {
        return $self->_restore_bookmark( $existing, $input );
    }

    return $self->_retry_bookmark_id($input);
}

sub _retry_bookmark_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->create_bookmark($input); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _reuse_bookmark_row ( $self, $input, $error ) {
    my $existing = $self->_existing_bookmark($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_restore_bookmark( $existing, $input );
}

sub _existing_bookmark ( $self, $input ) {
    return $self->find_for_user_target( $input->{user_id},
        $input->{target_type}, $input->{target_id}, );
}

sub _bookmark_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _bookmark_target_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $TARGET_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub create_bookmark ( $self, $input ) {
    my $bookmark = {
        bookmark_id => $self->id_service->uuid,
        user_id     => $input->{user_id},
        target_type => $input->{target_type},
        target_id   => $input->{target_id},
        note        => $input->{note} || q{},
        created_at  => $self->clock->now_iso8601,
        deleted_at  => undef,
    };

    $self->schema->resultset('Bookmark')->create($bookmark);

    return $bookmark;
}

sub find_for_user_target ( $self, $user_id, $target_type, $target_id ) {
    return $self->schema->resultset('Bookmark')->find(
        {
            user_id     => $user_id,
            target_type => $target_type,
            target_id   => $target_id,
        }
    );
}

sub status_for_user_target ( $self, $user_id, $target_type, $target_id ) {
    return { bookmarked => 0 } if !$user_id;

    my $bookmark =
      $self->find_for_user_target( $user_id, $target_type, $target_id );

    return { bookmarked => 0 } if !$bookmark;

    return {
        bookmarked  => defined _column( $bookmark, 'deleted_at' ) ? 0 : 1,
        bookmark_id => _column( $bookmark, 'bookmark_id' ),
        note        => _column( $bookmark, 'note' ),
    };
}

sub remove_bookmark ( $self, $bookmark_id ) {
    my $bookmark = $self->schema->resultset('Bookmark')->find($bookmark_id);

    return $self->_soft_delete_bookmark($bookmark);
}

sub remove_for_user_target ( $self, $input ) {
    my $bookmark =
      $self->find_for_user_target( $input->{user_id}, $input->{target_type},
        $input->{target_id}, );

    if ( !$bookmark ) {
        return { ok => 0, error => 'not_found' };
    }

    my $removed = $self->_soft_delete_bookmark($bookmark);
    $removed->{ok} = 1;

    return $removed;
}

sub _soft_delete_bookmark ( $self, $bookmark ) {
    my $bookmark_id = _column( $bookmark, 'bookmark_id' );
    my $existing    = _column( $bookmark, 'deleted_at' );
    if ( defined $existing ) {
        return {
            bookmark_id => $bookmark_id,
            deleted_at  => $existing,
            skipped     => 1,
        };
    }

    my $deleted_at = $self->clock->now_iso8601;
    $bookmark->update( { deleted_at => $deleted_at } );

    return {
        bookmark_id => $bookmark_id,
        deleted_at  => $deleted_at,
    };
}

sub list_for_user ( $self, $user_id, $options ) {
    my $search = $self->bookmarks_resultset( $user_id, $options || {} );

    return [ _rows($search) ];
}

sub list_page_for_user ( $self, $user_id, $options ) {
    my $page   = $self->page_window->plan($options);
    my $search = $self->bookmarks_resultset(
        $user_id,
        {
            %{ $options || {} },
            limit => $page->{fetch_rows},
            after => $page->{after},
        }
    );

    my @rows = _rows($search);

    return $self->page_window->page( \@rows, $page->{limit}, \@CURSOR_COLUMNS );
}

sub _restore_bookmark ( $self, $bookmark, $input ) {
    my $note    = $input->{note} || q{};
    my $skipped = _bookmark_already_active( $bookmark, $note );
    if ( !$skipped ) {
        $bookmark->update(
            {
                deleted_at => undef,
                note       => $note,
            }
        );
    }

    my $result = {
        bookmark_id => _column( $bookmark, 'bookmark_id' ),
        created_at  => _column( $bookmark, 'created_at' ),
        deleted_at  => undef,
        note        => $note,
        target_id   => $input->{target_id},
        target_type => $input->{target_type},
        user_id     => $input->{user_id},
    };
    if ($skipped) {
        $result->{skipped} = 1;
    }

    return $result;
}

sub _bookmark_already_active ( $bookmark, $note ) {
    if ( defined _column( $bookmark, 'deleted_at' ) ) {
        return 0;
    }
    if ( ( _column( $bookmark, 'note' ) || q{} ) ne $note ) {
        return 0;
    }

    return 1;
}

sub _readable_targets ( $self, $user_id, $viewer ) {
    return {} if !$self->readability;

    return {
        -and => [
            $self->readability->sources_condition(
                $viewer // $user_id,
                'me.target_type', 'me.target_id'
            )
        ]
    };
}

# The resultset a bookmarks page executes; public so tests and the
# query-plan evidence see the SQL that runs.
sub bookmarks_resultset ( $self, $user_id, $options ) {
    my $query = {
        user_id    => $user_id,
        deleted_at => undef,
        %{ $self->_readable_targets( $user_id, $options->{viewer} ) },
    };
    if ( $options->{target_type} ) {
        $query->{target_type} = $options->{target_type};
    }
    if ( $options->{after} ) {
        GPForum::Infrastructure::Keyset->after(
            $query,
            {
                direction => 'desc',
                id        => [ 'bookmark_id', $options->{after}{id} ],
                sort      => [ 'created_at',  $options->{after}{sort_value} ],
            }
        );
    }

    return $self->schema->resultset('Bookmark')->search_rs(
        $query,
        {
            order_by =>
              [ { -desc => 'created_at' }, { -desc => 'bookmark_id' } ],
            rows => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub _column ( $row, $column ) {
    return GPForum::Infrastructure::Row->column( $row, $column );
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Community::BookmarkStore - Saves, removes and lists a member's bookmarks.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Community::BookmarkStore->new(
        readability => GPForum::Service::Forum::Readability->new(
            schema => $schema,
        ),
        schema => $schema,
    );
    my $saved = $store->save_bookmark(
        {
            user_id     => $user_id,
            target_type => 'thread',
            target_id   => $thread_id,
            note        => 'read later',
        }
    );
    my $status = $store->status_for_user_target( $user_id, 'thread', $thread_id );
    my $page   = $store->list_page_for_user(
        $user_id,
        { target_type => 'thread', limit => 25, after => $cursor, viewer => $viewer },
    );
    $store->remove_for_user_target(
        { user_id => $user_id, target_type => 'thread', target_id => $thread_id } );

=head1 DESCRIPTION

A member has at most one C<bookmarks> row per target. Removing a bookmark
soft-deletes it by setting C<deleted_at>; saving it again restores the same
row, with the new note, rather than inserting another. Saving a bookmark
that is already active with the same note writes nothing and is reported as
C<skipped>.

A new bookmark is inserted inside a savepoint. If the insert loses a race
on the member's target (C<bookmarks_user_target_key>), the row the other
request inserted is restored instead. If it collides on the bookmark id
(C<bookmarks_pkey>), the target is looked up again and, when there is still
no row, the insert is retried once with a fresh id.

Lists show active bookmarks only, newest first. When C<readability> is set,
they keep only bookmarks whose post or thread the reader can still read,
judged in the query before C<LIMIT> (ADR 0102), so a page stays full. A
bookmark used to keep pointing at a thread after its category turned
private, showing its title to someone who had lost access.

=head1 SUBROUTINES/METHODS

=head2 save_bookmark

Takes a hash reference with C<user_id>, C<target_type>, C<target_id> and an
optional C<note> (empty when omitted). Creates the bookmark, or restores
the member's existing one for that target. Returns a hash reference with
C<bookmark_id>, C<user_id>, C<target_type>, C<target_id>, C<note>,
C<created_at> and C<deleted_at> (undef), plus C<< skipped => 1 >> when the
bookmark was already active with that note.

=head2 create_bookmark

Takes the same hash reference and inserts a new row with a fresh uuid and
the clock's time, with no check for an existing one. Returns the inserted
fields as a hash reference. Used by C<save_bookmark>; a unique conflict
propagates from here.

=head2 find_for_user_target

Takes a user id, a target type and a target id. Returns that member's
C<Bookmark> row for the target, active or soft-deleted, or undef.

=head2 status_for_user_target

Takes a user id, a target type and a target id. Returns
C<< { bookmarked => 0 } >> when there is no user id or no row; otherwise
C<bookmarked> (1 when active, 0 when soft-deleted), C<bookmark_id> and
C<note>.

=head2 remove_bookmark

Takes a bookmark id and soft-deletes that bookmark. Returns
C<< { bookmark_id, deleted_at } >>, with C<< skipped => 1 >> and the
earlier C<deleted_at> when it was already removed.

=head2 remove_for_user_target

Takes a hash reference with C<user_id>, C<target_type> and C<target_id>.
Returns C<< { ok => 0, error => 'not_found' } >> when the member has no
bookmark for the target; otherwise the result of the soft delete, as for
C<remove_bookmark>, with C<< ok => 1 >>.

=head2 list_for_user

Takes a user id and an optional hash reference of the options
C<bookmarks_resultset> takes. Returns an array reference of the rows, at
most C<limit> (default 50) of them.

=head2 list_page_for_user

Takes a user id and a hash reference with C<limit>, C<after> (the cursor
string from the URL), C<target_type> and C<viewer>. Returns the page hash
reference from L<GPForum::Service::Forum::PageWindow/page>: C<items>,
C<has_next> and C<next_cursor>, the cursor over C<created_at> and
C<bookmark_id>.

=head2 bookmarks_resultset

Takes a user id and a hash reference with optional C<target_type>,
C<after> (an already decoded C<< { sort_value, id } >>), C<limit> (default
50) and C<viewer> (the reader to judge readability for; defaults to the
user id). Returns the unexecuted C<Bookmark> resultset of the member's
active bookmarks, ordered by C<created_at> and then C<bookmark_id>,
descending. Public so tests and the query-plan evidence see the SQL that
runs.

=head1 DIAGNOSTICS

C<save_bookmark> croaks with the database error when the insert fails for
any reason other than a unique conflict, when a target conflict leaves no
row to restore, and when the retry after an id collision fails too.
C<remove_bookmark> dies when no bookmark has the given id, calling
C<update> on undef. Other database errors propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None. C<clock> and C<id_service> default to L<GPForum::Service::Clock> and
L<GPForum::Infrastructure::Id>; tests pass fixed ones.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::Id>, L<GPForum::Infrastructure::Keyset>,
L<GPForum::Infrastructure::Row>, L<GPForum::Infrastructure::UniqueConflict>,
L<GPForum::Service::Clock>, L<GPForum::Service::Forum::PageWindow>,
L<GPForum::Service::Forum::Readability> (passed in as C<readability>).

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
