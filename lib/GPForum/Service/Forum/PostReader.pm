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
        thread_id        => $request->{thread_id},
        deleted_at       => undef,
        moderation_state => 'visible',
    };
    if ( $plan->{after} ) {
        $query->{-or} = _post_cursor_clause( $plan->{after} );
    }

    my $search = $self->schema->resultset('Post')->search(
        $query,
        {
            prefetch => ['current_body'],
            order_by => [ { -asc => 'position' }, { -asc => 'post_id' }, ],
            rows     => $plan->{fetch_rows},
        }
    );

    return $self->page_window->page(
        [ _rows($search) ],
        $plan->{limit}, [ 'position', 'post_id' ],
    );
}

sub _post_cursor_clause {
    my ($after) = @_;

    return [
        { position => { '>' => $after->{sort_value} } },
        {
            position => $after->{sort_value},
            post_id  => { '>' => $after->{id} },
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
