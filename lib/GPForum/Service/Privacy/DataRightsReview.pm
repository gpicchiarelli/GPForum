package GPForum::Service::Privacy::DataRightsReview;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT => 50;

has schema => undef;

sub pending_deletion_requests {
    my ( $self, $options ) = @_;

    return $self->_search(
        'DeletionRequest',
        { status => 'pending' },
        {
            order_by => [ { -asc => 'created_at' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub erasure_jobs_by_status {
    my ( $self, $status, $options ) = @_;

    return $self->_search(
        'ErasureJob',
        { status => $status },
        {
            order_by => [ { -asc => 'scheduled_at' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub _search {
    my ( $self, $resultset, $query, $attrs ) = @_;

    my $search = $self->schema->resultset($resultset)->search( $query, $attrs );

    return [ _rows($search) ];
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
