package GPForum::Service::Community::BookmarkStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT => 50;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

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

sub remove_bookmark {
    my ( $self, $bookmark_id ) = @_;

    my $deleted_at = $self->clock->now_iso8601;
    my $bookmark   = $self->schema->resultset('Bookmark')->find($bookmark_id);
    $bookmark->update( { deleted_at => $deleted_at } );

    return { bookmark_id => $bookmark_id, deleted_at => $deleted_at };
}

sub list_for_user {
    my ( $self, $user_id, $options ) = @_;

    my $query = {
        user_id    => $user_id,
        deleted_at => undef,
    };
    if ( $options && $options->{target_type} ) {
        $query->{target_type} = $options->{target_type};
    }

    my $search = $self->schema->resultset('Bookmark')->search(
        $query,
        {
            order_by =>
              [ { -desc => 'created_at' }, { -desc => 'bookmark_id' } ],
            rows => $options->{limit} || $DEFAULT_LIMIT,
        }
    );

    return [ _rows($search) ];
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
