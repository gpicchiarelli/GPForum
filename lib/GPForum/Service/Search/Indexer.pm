package GPForum::Service::Search::Indexer;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha1_hex);
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;
use GPForum::Service::Search::DocumentBuilder;

our $VERSION = '0.001';

const my $VECTOR_EXPRESSION => q{
    setweight(to_tsvector(?, coalesce(?, '')), 'A') ||
    setweight(to_tsvector(?, coalesce(?, '')), 'B')
};

has builder => sub { return GPForum::Service::Search::DocumentBuilder->new; };
has clock   => sub { return GPForum::Service::Clock->new; };
has id_service     => sub { return GPForum::Service::Id->new; };
has offset_tracker => undef;
has schema         => undef;

sub index_thread {
    my ( $self, $thread_id ) = @_;

    my $thread = $self->schema->resultset('Thread')->find($thread_id);
    return $self->_remove_document( 'thread', $thread_id ) if !$thread;

    my $document = $self->builder->build_thread($thread);
    return $self->_remove_document( 'thread', $thread_id ) if !$document;

    return $self->_upsert_document($document);
}

sub index_post {
    my ( $self, $post_id ) = @_;

    my $post = $self->schema->resultset('Post')->find($post_id);
    return $self->remove_post($post_id) if !$post;

    my $document = $self->builder->build_post($post);
    return $self->remove_post($post_id) if !$document;

    return $self->_upsert_document($document);
}

sub remove_post {
    my ( $self, $post_id ) = @_;

    return $self->_remove_document( 'post', $post_id );
}

sub rebuild {
    my ( $self, $scope ) = @_;

    my $entity_type = $scope->{entity_type} || 'all';
    my @indexed     = $self->_rebuild_for_entity_type($entity_type);

    return {
        ok      => 1,
        indexed => scalar @indexed,
        rows    => \@indexed,
    };
}

sub _rebuild_for_entity_type {
    my ( $self, $entity_type ) = @_;

    return $self->_rebuild_threads if $entity_type eq 'thread';
    return $self->_rebuild_posts   if $entity_type eq 'post';

    return ( $self->_rebuild_threads, $self->_rebuild_posts );
}

sub observe_lag {
    my ($self) = @_;

    return if !$self->offset_tracker;

    return $self->offset_tracker->observe_lag('search_documents');
}

sub _rebuild_threads {
    my ($self) = @_;

    my $search = $self->schema->resultset('Thread')->search(
        {
            deleted_at       => undef,
            moderation_state => 'visible',
        }
    );

    return
      map { $self->index_thread( $_->get_column('thread_id') ) } _rows($search);
}

sub _rebuild_posts {
    my ($self) = @_;

    my $search = $self->schema->resultset('Post')->search(
        {
            deleted_at       => undef,
            moderation_state => 'visible',
        }
    );

    return
      map { $self->index_post( $_->get_column('post_id') ) } _rows($search);
}

sub _upsert_document {
    my ( $self, $document ) = @_;

    my $row = {
        search_document_id => _document_id_for($document),
        %{$document},
        indexed_at    => $self->clock->now_iso8601,
        search_vector => _search_vector_for($document),
    };

    $self->schema->resultset('SearchDocument')->update_or_create($row);

    return $row;
}

sub _remove_document {
    my ( $self, $entity_type, $entity_id ) = @_;

    my $search = $self->schema->resultset('SearchDocument')->search(
        {
            entity_type => $entity_type,
            entity_id   => $entity_id,
        }
    );
    $search->delete;

    return {
        ok          => 1,
        removed     => 1,
        entity_type => $entity_type,
        entity_id   => $entity_id,
    };
}

sub _search_vector_for {
    my ($document) = @_;

    return \[
        $VECTOR_EXPRESSION,
        [ language => $document->{language} ],
        [ title    => $document->{title} ],
        [ language => $document->{language} ],
        [ body     => $document->{body} ],
    ];
}

sub _document_id_for {
    my ($document) = @_;

    my $hex = sha1_hex(
        join q{:}, 'search_document',
        $document->{entity_type},
        $document->{entity_id}
    );

    return join q{-},
      substr( $hex, 0,  8 ),
      substr( $hex, 8,  4 ),
      substr( $hex, 12, 4 ),
      substr( $hex, 16, 4 ),
      substr( $hex, 20, 12 );
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
