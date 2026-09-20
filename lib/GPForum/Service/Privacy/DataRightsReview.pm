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

sub deletion_request {
    my ( $self, $request_id ) = @_;

    return $self->schema->resultset('DeletionRequest')->find($request_id);
}

sub deletion_requests_for_user {
    my ( $self, $user_id, $options ) = @_;

    return $self->_search(
        'DeletionRequest',
        {
            requester_user_id => $user_id,
            resource_type     => 'user',
            resource_id       => $user_id,
        },
        {
            order_by => [ { -desc => 'created_at' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub export_requests_for_user {
    my ( $self, $user_id, $options ) = @_;

    return $self->_search(
        'ExportRequest',
        {
            requester_user_id => $user_id,
            subject_user_id   => $user_id,
        },
        {
            order_by => [ { -desc => 'created_at' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub completed_export_for_user {
    my ( $self, $user_id, $export_request_id ) = @_;

    my $rows = $self->_search(
        'ExportRequest',
        {
            export_request_id => $export_request_id,
            requester_user_id => $user_id,
            status            => 'completed',
            subject_user_id   => $user_id,
        },
        { rows => 1 },
    );

    return $rows->[0];
}

sub pending_export_requests {
    my ( $self, $options ) = @_;

    return $self->_search(
        'ExportRequest',
        { status => 'pending' },
        {
            order_by => [ { -asc => 'created_at' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub active_holds_for_user {
    my ( $self, $user_id, $options ) = @_;

    return $self->_search(
        'RetentionHold',
        {
            resource_type => 'user',
            resource_id   => $user_id,
            ends_at       => undef,
        },
        {
            order_by => [ { -desc => 'created_at' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub active_holds {
    my ( $self, $options ) = @_;

    return $self->_search(
        'RetentionHold',
        { ends_at => undef },
        {
            order_by => [ { -desc => 'created_at' } ],
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
