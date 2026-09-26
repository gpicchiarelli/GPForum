# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Search::Indexer;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use List::Util  qw(none uniq);
use Digest::SHA qw(sha1_hex);
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::CountedQuery;
use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;
use GPForum::Service::Search::DocumentBuilder;

our $VERSION = '0.001';

const my $VECTOR_EXPRESSION => q{
    setweight(to_tsvector(?, coalesce(?, '')), 'A') ||
    setweight(to_tsvector(?, coalesce(?, '')), 'B')
};
const my $REBUILD_BATCH  => 500;
const my @REBUILD_COUNTS => qw(indexed pruned unchanged);

# What the document builder indexes: a live thread, visible or locked, and a
# live, visible post in such a thread.
const my %LIVE_STATES => (
    post   => ['visible'],
    thread => [qw(locked visible)],
);

# Documents whose source is gone, deleted or hidden: candidates only. Each is
# checked again under its document lock before it goes (see _prune).
const my %PRUNE_CANDIDATES_SQL => (
    post => join( q{ },
q{SELECT d.entity_id FROM search_documents d WHERE d.entity_type = 'post'},
        q{AND NOT EXISTS (SELECT 1 FROM posts p},
        q{JOIN threads t ON t.thread_id = p.thread_id},
        q{WHERE p.post_id = d.entity_id AND p.deleted_at IS NULL},
        q{AND p.moderation_state = 'visible' AND t.deleted_at IS NULL},
        q{AND t.moderation_state IN ('visible', 'locked'))} ),
    thread => join( q{ },
q{SELECT d.entity_id FROM search_documents d WHERE d.entity_type = 'thread'},
        q{AND NOT EXISTS (SELECT 1 FROM threads t},
        q{WHERE t.thread_id = d.entity_id AND t.deleted_at IS NULL},
        q{AND t.moderation_state IN ('visible', 'locked'))} ),
);

# Every outbox message is dispatched to every handler for its event, search
# included, so the oldest one not yet delivered bounds how far behind search
# can be.
const my $LAG_SQL => join q{ },
  q{SELECT count(*) AS pending, to_char(min(created_at) AT TIME ZONE 'UTC',},
  q{'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS oldest_pending_at,},
  q{coalesce(floor(extract(epoch FROM now() - min(created_at))), 0)},
  q{AS lag_seconds FROM outbox_messages},
  q{WHERE status IN ('pending', 'running', 'failed')};

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
has id_service     => sub { return GPForum::Infrastructure::Id->new; };
has offset_tracker => undef;

# Ids a rebuild step indexes: enough to be worth an outbox message, few
# enough that a step never holds the dispatcher for long.
has rebuild_batch_size => $REBUILD_BATCH;
has schema             => undef;

# How far search can be behind the forum. An offset tracker answers when one
# is wired; otherwise the outbox does, which every search update passes
# through.
sub observe_lag ($self) {
    return $self->offset_tracker->observe_lag('search_documents')
      if $self->offset_tracker;

    my $row =
      GPForum::Infrastructure::CountedQuery->select_row( $self->schema,
        $LAG_SQL );

    return {
        lag_seconds       => 0 + ( $row->{lag_seconds} // 0 ),
        oldest_pending_at => $row->{oldest_pending_at},
        pending           => 0 + ( $row->{pending} // 0 ),
        projection_name   => 'search_documents',
        status            => $row->{pending} ? 'behind' : 'current',
    };
}

sub index_thread ( $self, $thread_id ) {
    return $self->schema->txn_do(
        sub {
            return $self->_index_thread($thread_id);
        }
    );
}

# Reading the source row and rewriting search_documents are one unit: a
# document half written from a row that moved on indexes stale content.
sub _index_thread ( $self, $thread_id ) {
    $self->_lock_document( 'thread', $thread_id );
    my $thread = $self->schema->resultset('Thread')->find($thread_id);
    return $self->_remove_document( 'thread', $thread_id ) if !$thread;

    my $document = $self->builder->build_thread($thread);
    return $self->_remove_document( 'thread', $thread_id ) if !$document;

    return $self->_upsert_document($document);
}

# Batch drivers stay outside a single transaction on purpose: each entity
# below is already atomic and a corpus-wide transaction would pin the
# snapshot for the whole rebuild.
sub index_thread_posts ( $self, $thread_id ) {
    my @indexed;
    for my $post_id ( $self->_post_ids_for_thread($thread_id) ) {
        push @indexed, $self->index_post($post_id);
    }

    return \@indexed;
}

sub index_post ( $self, $post_id ) {
    return $self->schema->txn_do(
        sub {
            return $self->_index_post($post_id);
        }
    );
}

sub _index_post ( $self, $post_id ) {
    $self->_lock_document( 'post', $post_id );
    my $post = $self->schema->resultset('Post')->find($post_id);
    return $self->_remove_document( 'post', $post_id ) if !$post;

    my $document = $self->builder->build_post($post);
    return $self->_remove_document( 'post', $post_id ) if !$document;

    return $self->_upsert_document($document);
}

sub remove_post ( $self, $post_id ) {
    return $self->schema->txn_do(
        sub {
            return $self->_remove_document( 'post', $post_id );
        }
    );
}

sub remove_thread ( $self, $thread_id ) {
    return $self->schema->txn_do(
        sub {
            return $self->_remove_thread($thread_id);
        }
    );
}

# A thread's documents and every post document leave the index together, or
# deleted content stays searchable.
sub _remove_thread ( $self, $thread_id ) {
    my $posts_removed = $self->_remove_posts_for_thread($thread_id);
    my $result        = $self->_remove_document( 'thread', $thread_id );
    $result->{posts_removed} = $posts_removed;

    return $result;
}

# Rebuilds the projection from the canonical rows (ADR 0062), after a
# search configuration change, a handler bug or dead-lettered events: every
# live thread and post is indexed again, a batch of ids at a time so memory
# stays flat however large the forum, and documents whose source is gone,
# deleted or hidden are removed. It returned every row it indexed, and kept
# locked threads and orphaned documents out of the rebuild.
sub rebuild ( $self, $scope ) {
    my $entity_type = $scope->{entity_type} || 'all';
    my %summary     = (
        entity_type => $entity_type,
        indexed     => 0,
        ok          => 1,
        pruned      => 0,
        unchanged   => 0,
    );
    my $cursor = { entity_type => $entity_type };
    while ($cursor) {
        my $step = $self->rebuild_batch($cursor);
        for my $count (@REBUILD_COUNTS) {
            $summary{$count} += $step->{$count};
        }
        $cursor = $step->{next};
    }

    return \%summary;
}

# One step of a rebuild: up to 500 ids of one entity type, or, last, the
# removal of orphaned documents. $cursor holds entity_type (thread, post or
# all), stage (the type being indexed, or prune) and after (the last id
# done). Returns this step's counts and the next cursor, or none when the
# rebuild is done. The console's rebuild runs one step per outbox message,
# so a large forum never holds the dispatcher for long.
sub rebuild_batch ( $self, $cursor ) {
    my @types  = _rebuild_types( $cursor->{entity_type} );
    my $stage  = $cursor->{stage} || $types[0];
    my %counts = map { $_ => 0 } @REBUILD_COUNTS;

    if ( $stage eq 'prune' ) {

        # A dead thread's posts go with it, whichever type was rebuilt: the
        # post prune removes only posts that are dead or in a dead thread.
        for my $type ( uniq( @types, 'post' ) ) {
            $counts{pruned} += $self->_prune($type);
        }
        return { %counts, next => undef };
    }
    croak "unknown rebuild stage: $stage" if none { $_ eq $stage } @types;

    my @ids = $self->_live_ids( $stage, $cursor->{after} );
    for my $id (@ids) {
        my $result =
            $stage eq 'thread'
          ? $self->index_thread($id)
          : $self->index_post($id);
        $counts{ _rebuild_outcome($result) }++;
    }

    my %next = ( entity_type => $cursor->{entity_type} || 'all' );
    if ( @ids == $self->rebuild_batch_size ) {
        @next{qw(stage after)} = ( $stage, $ids[-1] );
    }
    else {
        $next{stage} = _stage_after( $stage, @types );
    }

    return { %counts, next => \%next };
}

sub _rebuild_types ($entity_type) {
    my $type = $entity_type || 'all';
    return qw(thread post) if $type eq 'all';
    return ($type)         if exists $LIVE_STATES{$type};

    croak "unknown rebuild entity type: $type";
}

sub _stage_after ( $stage, @types ) {
    my ($position) = grep { $types[$_] eq $stage } 0 .. $#types;

    return $position < $#types ? $types[ $position + 1 ] : 'prune';
}

sub _rebuild_outcome ($result) {
    return 'unchanged'                                 if $result->{skipped};
    return $result->{deleted} ? 'pruned' : 'unchanged' if $result->{removed};

    return 'indexed';
}

# The ids the document builder will index: a post counts only in a live
# thread, or every rebuild would visit, and remove again, the posts of a
# hidden thread.
sub _live_ids ( $self, $type, $after ) {
    my $key    = "${type}_id";
    my %thread = (
        'thread.deleted_at'       => undef,
        'thread.moderation_state' => { -in => $LIVE_STATES{thread} },
    );

    return map { _column( $_, $key ) } _rows(
        $self->schema->resultset( ucfirst $type )->search_rs(
            {
                'me.deleted_at'       => undef,
                'me.moderation_state' => { -in => $LIVE_STATES{$type} },
                ( $type eq 'post' ? %thread                             : () ),
                ( defined $after  ? ( "me.$key" => { q{>} => $after } ) : () ),
            },
            {
                columns  => ["me.$key"],
                order_by => { -asc => "me.$key" },
                rows     => $self->rebuild_batch_size,
                ( $type eq 'post' ? ( join => 'thread' ) : () ),
            }
        )
    );
}

# Two phases. The candidates are read from one snapshot, then each is
# indexed again under its document lock: a source restored since the
# snapshot is indexed rather than lost, and only what is still dead goes.
sub _prune ( $self, $type ) {
    my $storage = $self->schema->storage;
    return 0 if !$storage->can('dbh_do');

    my $candidates = $storage->dbh_do(
        sub ( $, $dbh ) {
            return $dbh->selectcol_arrayref( $PRUNE_CANDIDATES_SQL{$type} );
        }
    );
    my $pruned = 0;
    for my $id ( @{ $candidates || [] } ) {
        my $result =
          $type eq 'thread' ? $self->index_thread($id) : $self->index_post($id);
        if ( _rebuild_outcome($result) eq 'pruned' ) {
            $pruned++;
        }
    }

    return $pruned;
}

sub _remove_posts_for_thread ( $self, $thread_id ) {
    my $removed = 0;
    for my $post_id ( $self->_post_ids_for_thread($thread_id) ) {
        $self->_remove_document( 'post', $post_id );
        $removed++;
    }

    return $removed;
}

sub _post_ids_for_thread ( $self, $thread_id ) {
    my $search = $self->_posts_for_thread($thread_id);
    if ( !$search ) {
        return;
    }

    return map { $_->get_column('post_id') } _rows($search);
}

sub _posts_for_thread ( $self, $thread_id ) {
    my $posts = $self->_post_resultset;
    if ( !$posts ) {
        return;
    }

    return $posts->search_rs( { thread_id => $thread_id } );
}

sub _post_resultset ($self) {
    my $schema = $self->schema;
    if ( !$schema ) {
        return;
    }

    return $schema->resultset('Post');
}

sub _upsert_document ( $self, $document ) {
    my $existing = $self->_existing_document($document);
    if ( _unchanged_document( $existing, $document ) ) {
        return _skipped_document($existing);
    }
    if ($existing) {
        return $self->_write_document($document);
    }

    return $self->_insert_or_reuse_document($document);
}

# The insert runs inside txn_do now, so a unique race has to be contained by
# a savepoint instead of aborting the whole transaction.
sub _insert_or_reuse_document ( $self, $document ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_document($document); },
      );
    if ($created) {
        return $created;
    }

    return $self->_document_after_conflict( $document, $error );
}

sub _document_after_conflict ( $self, $document, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $existing = $self->_existing_document($document);
    if ( !_unchanged_document( $existing, $document ) ) {
        return $self->_write_after_conflict( $existing, $document, $error );
    }

    return _skipped_document($existing);
}

sub _write_after_conflict ( $self, $existing, $document, $error ) {
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_write_document($document);
}

sub _insert_document ( $self, $document ) {
    my $row = $self->_document_row($document);
    $self->schema->resultset('SearchDocument')->create($row);

    return $row;
}

sub _existing_document ( $self, $document ) {
    my $search = $self->schema->resultset('SearchDocument')->search_rs(
        {
            entity_id   => $document->{entity_id},
            entity_type => $document->{entity_type},
        }
    );
    my @rows = _rows($search);

    return $rows[0];
}

sub _unchanged_document ( $existing, $document ) {
    if ( !$existing ) {
        return 0;
    }

    return _same_document( $existing, $document );
}

sub _same_document ( $held, $incoming ) {
    for my $name (@DOCUMENT_COPY) {
        if ( !_same_text( _column( $held, $name ), $incoming->{$name} ) ) {
            return 0;
        }
    }

    return 1;
}

sub _same_text ( $held, $incoming ) {
    $held     = defined $held     ? $held     : q{};
    $incoming = defined $incoming ? $incoming : q{};

    return $held eq $incoming ? 1 : 0;
}

sub _skipped_document ($existing) {
    return {
        entity_id      => _column( $existing, 'entity_id' ),
        entity_type    => _column( $existing, 'entity_type' ),
        indexed_at     => _column( $existing, 'indexed_at' ),
        skipped        => 1,
        source_version => _column( $existing, 'source_version' ),
    };
}

sub _write_document ( $self, $document ) {
    my $row = $self->_document_row($document);
    $self->schema->resultset('SearchDocument')->update_or_create($row);

    return $row;
}

sub _document_row ( $self, $document ) {
    return {
        search_document_id => _document_id_for($document),
        %{$document},
        indexed_at    => $self->clock->now_iso8601,
        search_vector => _search_vector_for($document),
    };
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

sub _remove_document ( $self, $entity_type, $entity_id ) {
    $self->_lock_document( $entity_type, $entity_id );
    my $search = $self->schema->resultset('SearchDocument')->search_rs(
        {
            entity_type => $entity_type,
            entity_id   => $entity_id,
        }
    );
    my $deleted = $search->delete;

    return {
        deleted     => 0 + ( $deleted // 0 ),
        entity_id   => $entity_id,
        entity_type => $entity_type,
        ok          => 1,
        removed     => 1,
    };
}

# One writer per document at a time, until the transaction ends. A rebuild
# and the live search handler could otherwise interleave -- the rebuild
# reads the old source, the handler writes the new document, the rebuild
# writes the old one back -- and the stale document would stay, a hidden
# post searchable among them. A source change commits before its event is
# dispatched, so whichever takes the lock second reads the newest source.
# The lock is on the document's name, not on any forum row.
sub _lock_document ( $self, $entity_type, $entity_id ) {
    my $storage = $self->schema->storage;
    return if !$storage->can('dbh_do');

    $storage->dbh_do(
        sub ( $, $dbh ) {
            return $dbh->do(
                'SELECT pg_advisory_xact_lock(hashtextextended(?, 0))',
                undef, "search_document:$entity_type:$entity_id" );
        }
    );

    return;
}

sub _search_vector_for ($document) {
    return \[
        $VECTOR_EXPRESSION,
        [ language => $document->{language} ],
        [ title    => $document->{title} ],
        [ language => $document->{language} ],
        [ body     => $document->{body} ],
    ];
}

sub _document_id_for ($document) {
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

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
