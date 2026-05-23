package GPForum::Service::Community::FeedReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Forum::PageWindow;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT  => 25;
const my @CURSOR_COLUMNS => qw(created_at item_id);

has page_window => sub { return GPForum::Service::Forum::PageWindow->new; };
has schema      => undef;

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

sub _search_for_user {
    my ( $self, $user_id, $options ) = @_;

    my $query = { user_id => $user_id };
    if ( $options->{after} ) {
        $query->{-or} = [
            { created_at => { q{<} => $options->{after}{sort_value} } },
            {
                -and => [
                    { created_at => $options->{after}{sort_value} },
                    { item_id    => { q{<} => $options->{after}{id} } },
                ],
            },
        ];
    }

    return $self->schema->resultset('UserFeedItem')->search(
        $query,
        {
            columns => [
                qw(
                  user_id item_type item_id created_at rank_score
                  visibility_version permission_version
                )
            ],
            order_by => [ { -desc => 'created_at' }, { -desc => 'item_id' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
