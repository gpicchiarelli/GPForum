package GPForum::Service::Forum::PostPosition;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $FIRST_POSITION => 1;

has schema => undef;

sub next_position {
    my ( $self, $thread_id ) = @_;

    my $posts  = $self->schema->resultset('Post');
    my $search = $posts->search(
        { thread_id => $thread_id },
        {
            order_by => [ { -desc => 'position' }, { -desc => 'post_id' }, ],
            rows     => 1,
        }
    );
    my $latest = $search->single;

    return $FIRST_POSITION if !$latest;

    return $latest->get_column('position') + 1;
}

1;
