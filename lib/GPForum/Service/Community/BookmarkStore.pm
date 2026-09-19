package GPForum::Service::Community::BookmarkStore;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Forum::PageWindow;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT  => 50;
const my @CURSOR_COLUMNS => qw(created_at bookmark_id);

has clock       => sub { return GPForum::Service::Clock->new; };
has id_service  => sub { return GPForum::Service::Id->new; };
has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

sub save_bookmark {
    my ( $self, $input ) = @_;

    my $existing =
      $self->find_for_user_target( $input->{user_id}, $input->{target_type},
        $input->{target_id}, );

    if ($existing) {
        return $self->_restore_bookmark( $existing, $input );
    }

    return $self->_insert_or_restore($input);
}

sub _insert_or_restore {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->create_bookmark($input); };
    my $error   = $EVAL_ERROR;
    if ($created) {
        return $created;
    }

    return $self->_restore_after_conflict( $input, $error );
}

sub _restore_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $existing =
      $self->find_for_user_target( $input->{user_id}, $input->{target_type},
        $input->{target_id}, );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_restore_bookmark( $existing, $input );
}

sub create_bookmark {
    my ( $self, $input ) = @_;

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

sub find_for_user_target {
    my ( $self, $user_id, $target_type, $target_id ) = @_;

    return $self->schema->resultset('Bookmark')->find(
        {
            user_id     => $user_id,
            target_type => $target_type,
            target_id   => $target_id,
        }
    );
}

sub status_for_user_target {
    my ( $self, $user_id, $target_type, $target_id ) = @_;

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

sub remove_bookmark {
    my ( $self, $bookmark_id ) = @_;

    my $deleted_at = $self->clock->now_iso8601;
    my $bookmark   = $self->schema->resultset('Bookmark')->find($bookmark_id);
    $bookmark->update( { deleted_at => $deleted_at } );

    return { bookmark_id => $bookmark_id, deleted_at => $deleted_at };
}

sub remove_for_user_target {
    my ( $self, $input ) = @_;

    my $bookmark =
      $self->find_for_user_target( $input->{user_id}, $input->{target_type},
        $input->{target_id}, );

    return { ok => 0, error => 'not_found' } if !$bookmark;

    my $deleted_at = $self->clock->now_iso8601;
    $bookmark->update( { deleted_at => $deleted_at } );

    return {
        ok          => 1,
        bookmark_id => _column( $bookmark, 'bookmark_id' ),
        deleted_at  => $deleted_at,
    };
}

sub list_for_user {
    my ( $self, $user_id, $options ) = @_;

    my $search = $self->_search_for_user( $user_id, $options || {} );

    return [ _rows($search) ];
}

sub list_page_for_user {
    my ( $self, $user_id, $options ) = @_;

    my $page   = $self->page_window->plan($options);
    my $search = $self->_search_for_user(
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

sub _restore_bookmark {
    my ( $self, $bookmark, $input ) = @_;

    my $changes = {
        note       => $input->{note} || q{},
        deleted_at => undef,
    };
    $bookmark->update($changes);

    return {
        bookmark_id => _column( $bookmark, 'bookmark_id' ),
        user_id     => $input->{user_id},
        target_type => $input->{target_type},
        target_id   => $input->{target_id},
        note        => $changes->{note},
        created_at  => _column( $bookmark, 'created_at' ),
        deleted_at  => undef,
    };
}

sub _search_for_user {
    my ( $self, $user_id, $options ) = @_;

    my $query = {
        user_id    => $user_id,
        deleted_at => undef,
    };
    if ( $options->{target_type} ) {
        $query->{target_type} = $options->{target_type};
    }
    if ( $options->{after} ) {
        $query->{-or} = [
            { created_at => { q{<} => $options->{after}{sort_value} } },
            {
                -and => [
                    { created_at  => $options->{after}{sort_value} },
                    { bookmark_id => { q{<} => $options->{after}{id} } },
                ],
            },
        ];
    }

    return $self->schema->resultset('Bookmark')->search(
        $query,
        {
            order_by =>
              [ { -desc => 'created_at' }, { -desc => 'bookmark_id' } ],
            rows => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row && $row->can('get_column');

    return;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
