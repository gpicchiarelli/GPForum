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
        'me.deleted_at'       => undef,
        'me.moderation_state' => 'visible',
        'me.visibility'       => 'public',
    };
    if ( $plan->{after} ) {
        $query->{-or} = _post_cursor_clause( $plan->{after} );
    }

    my $search = $self->schema->resultset('Post')->search(
        $query,
        {
            columns => [
                qw(
                  post_id thread_id author_user_id current_body_id position
                  visibility moderation_state
                )
            ],
            join      => [ 'current_body', 'author' ],
            '+select' => [
                'current_body.body_rendered_safe', 'author.username',
                'author.display_name',
            ],
            '+as'    => [qw(body author_username author_display_name)],
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
