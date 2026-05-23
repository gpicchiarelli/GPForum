package GPForum::Service::Search::Searcher;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT  => 20;
const my $AT_CODE        => 64;
const my $MATCH_OPERATOR => join q{}, chr $AT_CODE, chr $AT_CODE;

has permission_engine => undef;
has schema            => undef;

sub search {
    my ( $self, $actor, $query, $options ) = @_;

    $options ||= {};

    my @visibility = $self->_visibility_for( $actor, $options );
    my $limit      = $options->{limit} || $DEFAULT_LIMIT;
    my $search     = $self->schema->resultset('SearchDocument')->search(
        {
            visibility       => { -in             => \@visibility },
            permission_scope => { -in             => \@visibility },
            search_vector    => { $MATCH_OPERATOR => $query },
        },
        {
            rows     => $limit,
            order_by => [ { -desc => 'indexed_at' } ],
        }
    );

    return [ grep { $self->_can_render( $actor, $_ ) } _rows($search) ];
}

sub autocomplete {
    my ( $self, $actor, $prefix, $options ) = @_;

    $options ||= {};

    my @visibility = $self->_visibility_for( $actor, $options );
    my $limit      = $options->{limit} || $DEFAULT_LIMIT;
    my $search     = $self->schema->resultset('SearchDocument')->search(
        {
            visibility       => { -in   => \@visibility },
            permission_scope => { -in   => \@visibility },
            title_normalized => { -like => lc $prefix . q{%} },
        },
        {
            rows     => $limit,
            order_by => ['title_normalized'],
        }
    );

    return [ grep { $self->_can_render( $actor, $_ ) } _rows($search) ];
}

sub _visibility_for {
    my ( $self, $actor, $options ) = @_;

    return $self->permission_engine->search_visibility_for( $actor, $options )
      if $self->permission_engine;

    return ('public');
}

sub _can_render {
    my ( $self, $actor, $row ) = @_;

    return 1 if !$self->permission_engine;

    return $self->permission_engine->can(
        $actor,
        'search.view',
        {
            entity_type => $row->get_column('entity_type'),
            entity_id   => $row->get_column('entity_id'),
            visibility  => $row->get_column('visibility'),
        },
        {}
    );
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
