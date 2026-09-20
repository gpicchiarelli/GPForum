package GPForum::Service::Forum::PostReader;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Forum::PageWindow;

our $VERSION = '0.001';

has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

sub list_thread_posts {
    my ( $self, $request ) = @_;

    my $plan  = $self->page_window->plan($request);
    my $query = {
        'me.thread_id'        => $request->{thread_id},
        'me.moderation_state' => 'visible',
        'me.visibility'       => 'public',
    };
    _apply_deleted_filter( $query, $request );
    if ( $plan->{after} ) {
        _apply_cursor( $query, $plan->{after} );
    }

    my $search = $self->schema->resultset('Post')->search(
        $query,
        {
            columns => [
                qw(
                  post_id thread_id author_user_id current_body_id position
                  visibility moderation_state deleted_at
                )
            ],
            join      => [ 'current_body', 'author' ],
            '+select' => [
                'current_body.body_rendered_safe', 'current_body.body_source',
                'author.username',                 'author.display_name',
            ],
            '+as' => [qw(body body_source author_username author_display_name)],
            order_by =>
              [ { -asc => 'me.position' }, { -asc => 'me.post_id' }, ],
            rows => $plan->{fetch_rows},
        }
    );

    return $self->page_window->page(
        [ _rows($search) ],
        $plan->{limit}, [ 'position', 'post_id' ],
    );
}

sub find_visible_post {
    my ( $self, $post_id ) = @_;

    return if !defined $post_id || !length $post_id;

    my $search = $self->schema->resultset('Post')->search(
        {
            post_id          => $post_id,
            deleted_at       => undef,
            moderation_state => 'visible',
            visibility       => 'public',
        },
        { rows => 1, }
    );

    return $search->single;
}

sub _apply_deleted_filter {
    my ( $query, $request ) = @_;

    my $viewer = $request->{viewer_user_id};
    if ( defined $viewer && length $viewer ) {
        $query->{-or} = _viewer_deleted_clause($viewer);
        return;
    }

    $query->{'me.deleted_at'} = undef;

    return;
}

sub _viewer_deleted_clause {
    my ($viewer) = @_;

    return [ { 'me.deleted_at' => undef },
        { 'me.author_user_id' => $viewer }, ];
}

sub _apply_cursor {
    my ( $query, $after ) = @_;

    my $cursor = _post_cursor_clause($after);
    if ( exists $query->{-or} ) {
        $query->{-and} =
          [ { -or => delete $query->{-or} }, { -or => $cursor } ];
        return;
    }

    $query->{-or} = $cursor;

    return;
}

sub find_post {
    my ( $self, $post_id ) = @_;

    if ( !defined $post_id || !length $post_id ) {
        return;
    }

    return $self->schema->resultset('Post')->find( { post_id => $post_id } );
}

sub _post_cursor_clause {
    my ($after) = @_;

    return [
        { 'me.position' => { '>' => $after->{sort_value} } },
        {
            'me.position' => $after->{sort_value},
            'me.post_id'  => { '>' => $after->{id} },
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
