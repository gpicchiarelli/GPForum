package GPForum::Service::Admin::AuditReview;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT => 50;

has schema => undef;

sub recent {
    my ( $self, $options ) = @_;

    return $self->_search(
        {},
        {
            order_by => [ { -desc => 'created_at' }, { -desc => 'audit_id' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub for_target {
    my ( $self, $target_type, $target_id, $options ) = @_;

    return $self->_search(
        {
            target_type => $target_type,
            target_id   => $target_id,
        },
        {
            order_by => [ { -desc => 'created_at' }, { -desc => 'audit_id' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub _search {
    my ( $self, $query, $attrs ) = @_;

    my $search = $self->schema->resultset('AuditLog')->search( $query, $attrs );

    return [ _rows($search) ];
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
