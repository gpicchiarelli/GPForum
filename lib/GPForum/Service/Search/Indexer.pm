package GPForum::Service::Search::Indexer;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha1_hex);
use English     qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Id;
use GPForum::Service::Search::DocumentBuilder;

our $VERSION = '0.001';

const my $VECTOR_EXPRESSION => q{
    setweight(to_tsvector(?, coalesce(?, '')), 'A') ||
    setweight(to_tsvector(?, coalesce(?, '')), 'B')
};
const my @DOCUMENT_COPY => qw(
  author_user_id
  body
  category_id
  language
  permission_scope
  permission_version
  source_created_at
  source_version
  space_id
  title
  visibility
  visibility_version
);

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

sub index_thread_posts {
    my ( $self, $thread_id ) = @_;

    my @indexed;
    for my $post_id ( $self->_post_ids_for_thread($thread_id) ) {
        push @indexed, $self->index_post($post_id);
    }

    return \@indexed;
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

sub remove_thread {
    my ( $self, $thread_id ) = @_;

    my $posts_removed = $self->_remove_posts_for_thread($thread_id);
    my $result        = $self->_remove_document( 'thread', $thread_id );
    $result->{posts_removed} = $posts_removed;

    return $result;
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

sub _remove_posts_for_thread {
    my ( $self, $thread_id ) = @_;

    my $removed = 0;
    for my $post_id ( $self->_post_ids_for_thread($thread_id) ) {
        $self->remove_post($post_id);
        $removed++;
    }

    return $removed;
}

sub _post_ids_for_thread {
    my ( $self, $thread_id ) = @_;

    my $search = $self->_posts_for_thread($thread_id);
    if ( !$search ) {
        return;
    }

    return map { $_->get_column('post_id') } _rows($search);
}

sub _posts_for_thread {
    my ( $self, $thread_id ) = @_;

    my $posts = $self->_post_resultset;
    if ( !$posts ) {
        return;
    }

    return $posts->search( { thread_id => $thread_id } );
}

sub _post_resultset {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( !$schema ) {
        return;
    }

    return $schema->resultset('Post');
}

sub _upsert_document {
    my ( $self, $document ) = @_;

    my $existing = $self->_existing_document($document);
    if ( _unchanged_document( $existing, $document ) ) {
        return _skipped_document($existing);
    }
    if ($existing) {
        return $self->_write_document($document);
    }

    return $self->_insert_or_reuse_document($document);
}

sub _insert_or_reuse_document {
    my ( $self, $document ) = @_;

    my $created = eval { return $self->_insert_document($document); };
    if ($created) {
        return $created;
    }

    return $self->_document_after_conflict( $document, $EVAL_ERROR );
}

sub _document_after_conflict {
    my ( $self, $document, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $existing = $self->_existing_document($document);
    if ( !_unchanged_document( $existing, $document ) ) {
        return $self->_write_after_conflict( $existing, $document, $error );
    }

    return _skipped_document($existing);
}

sub _write_after_conflict {
    my ( $self, $existing, $document, $error ) = @_;

    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_write_document($document);
}

sub _insert_document {
    my ( $self, $document ) = @_;

    my $row = $self->_document_row($document);
    $self->schema->resultset('SearchDocument')->create($row);

    return $row;
}

sub _existing_document {
    my ( $self, $document ) = @_;

    my $search = $self->schema->resultset('SearchDocument')->search(
        {
            entity_id   => $document->{entity_id},
            entity_type => $document->{entity_type},
        }
    );
    my @rows = _rows($search);

    return $rows[0];
}

sub _unchanged_document {
    my ( $existing, $document ) = @_;

    if ( !$existing ) {
        return 0;
    }

    return _same_document( $existing, $document );
}

sub _same_document {
    my ( $held, $incoming ) = @_;

    for my $name (@DOCUMENT_COPY) {
        if ( !_same_text( _column( $held, $name ), $incoming->{$name} ) ) {
            return 0;
        }
    }

    return 1;
}

sub _same_text {
    my ( $held, $incoming ) = @_;

    $held     = defined $held     ? $held     : q{};
    $incoming = defined $incoming ? $incoming : q{};

    return $held eq $incoming ? 1 : 0;
}

sub _skipped_document {
    my ($existing) = @_;

    return {
        entity_id      => _column( $existing, 'entity_id' ),
        entity_type    => _column( $existing, 'entity_type' ),
        indexed_at     => _column( $existing, 'indexed_at' ),
        skipped        => 1,
        source_version => _column( $existing, 'source_version' ),
    };
}

sub _write_document {
    my ( $self, $document ) = @_;

    my $row = $self->_document_row($document);
    $self->schema->resultset('SearchDocument')->update_or_create($row);

    return $row;
}

sub _document_row {
    my ( $self, $document ) = @_;

    return {
        search_document_id => _document_id_for($document),
        %{$document},
        indexed_at    => $self->clock->now_iso8601,
        search_vector => _search_vector_for($document),
    };
}

sub _column {
    my ( $row, $name ) = @_;

    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }
    if ( $row && $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return;
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
