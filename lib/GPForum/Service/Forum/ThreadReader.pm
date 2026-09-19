package GPForum::Service::Forum::ThreadReader;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Forum::PageWindow;

our $VERSION = '0.001';

has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

sub list_category_threads {
    my ( $self, $request ) = @_;

    my $plan  = $self->page_window->plan($request);
    my $query = {
        'me.category_id'      => $request->{category_id},
        'me.deleted_at'       => undef,
        'me.moderation_state' => { -in => [ 'visible', 'locked' ] },
        'me.visibility'       => 'public',
    };
    if ( $plan->{after} ) {
        $query->{-or} = _thread_cursor_clause( $plan->{after} );
    }

    my $search = $self->schema->resultset('Thread')->search(
        $query,
        {
            columns => [
                qw(
                  thread_id category_id author_user_id title slug pinned
                  visibility moderation_state locked_at last_activity_at
                  created_at deleted_at
                )
            ],
            join      => 'author',
            '+select' => [ 'author.username', 'author.display_name' ],
            '+as'     => [qw(author_username author_display_name)],
            order_by  => [
                { -desc => 'me.pinned' },
                { -desc => 'me.last_activity_at' },
                { -desc => 'me.thread_id' },
            ],
            rows => $plan->{fetch_rows},
        }
    );

    return $self->page_window->page(
        [ _rows($search) ],
        $plan->{limit}, [ 'last_activity_at', 'thread_id' ],
    );
}

sub list_public_threads {
    my ( $self, $request ) = @_;

    my $plan  = $self->page_window->plan($request);
    my $query = {
        'me.deleted_at'       => undef,
        'me.moderation_state' => { -in => [ 'visible', 'locked' ] },
        'me.visibility'       => 'public',
    };
    if ( $plan->{after} ) {
        $query->{-or} = _thread_cursor_clause( $plan->{after} );
    }

    my $search = $self->schema->resultset('Thread')->search(
        $query,
        {
            columns => [
                qw(
                  thread_id category_id author_user_id title slug pinned
                  visibility moderation_state last_activity_at created_at
                  deleted_at
                )
            ],
            join      => 'author',
            '+select' => [ 'author.username', 'author.display_name' ],
            '+as'     => [qw(author_username author_display_name)],
            order_by  => [
                { -desc => 'me.last_activity_at' },
                { -desc => 'me.thread_id' },
            ],
            rows => $plan->{fetch_rows},
        }
    );

    return $self->page_window->page(
        [ _rows($search) ],
        $plan->{limit}, [ 'last_activity_at', 'thread_id' ],
    );
}

sub _thread_cursor_clause {
    my ($after) = @_;

    return [
        { 'me.last_activity_at' => { '<' => $after->{sort_value} } },
        {
            'me.last_activity_at' => $after->{sort_value},
            'me.thread_id'        => { '<' => $after->{id} },
        },
    ];
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
