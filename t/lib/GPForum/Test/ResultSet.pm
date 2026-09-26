# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ResultSet;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::Query;

our $VERSION = '0.001';

const my %STORAGE_ACCESSOR_FOR => (
    CommandLog         => 'command_logs',
    Credential         => 'credentials',
    AuditLog           => 'audit_logs',
    EventLog           => 'event_logs',
    IdentityToken      => 'identity_tokens',
    OutboxMessage      => 'outbox_messages',
    Post               => 'posts',
    PostBody           => 'post_bodies',
    Report             => 'reports',
    Session            => 'sessions',
    PostRevision       => 'post_revisions',
    Thread             => 'threads',
    ThreadCounter      => 'thread_counters',
    ThreadCounterShard => 'thread_counter_shards',
    User               => 'users',
);

has schema => undef;
has name   => undef;
has rows   => sub { return; };

sub find {
    my ( $self, $query ) = @_;

    $self->_assert_usable;
    if ( $self->_consume_find_miss ) {
        return;
    }

    return _find_user( $self, $query )    if $self->name eq 'User';
    return _find_session( $self, $query ) if $self->name eq 'Session';

    return _find_storage_row( $self, $query );
}

sub count {
    my ($self) = @_;

    $self->_assert_usable;
    return 0 if !$self->rows;

    return scalar @{ $self->rows };
}

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_usable;
    $self->_assert_unique_constraints($row);
    push @{ $self->schema->created_for( $self->name ) }, $row;
    push @{ $self->_storage_rows }, $row if $self->_has_storage_rows;

    return $row;
}

# A unique violation is what puts a real transaction into the aborted state.
# Marking it here is what makes the doubles able to fail a recovery path that
# would be unreachable against PostgreSQL.
sub _assert_unique_constraints {
    my ( $self, $row ) = @_;

    my $ok = eval {
        $self->_run_unique_constraints($row);
        1;
    };
    if ( !$ok ) {
        my $failure = $@;
        $self->_mark_aborted;
        die $failure;    ## no critic (ErrorHandling::RequireCarping)
    }

    return;
}

sub _assert_usable {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( $schema && $schema->can('assert_transaction_usable') ) {
        $schema->assert_transaction_usable;
    }

    return;
}

sub _mark_aborted {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( $schema && $schema->can('mark_transaction_aborted') ) {
        $schema->mark_transaction_aborted;
    }

    return;
}

sub _run_unique_constraints {
    my ( $self, $row ) = @_;

    $self->_assert_command_id_unique($row);
    $self->_assert_command_unique($row);
    $self->_assert_token_id_unique($row);
    $self->_assert_open_token_unique($row);
    $self->_assert_token_hash_unique($row);
    $self->_assert_outbox_id_unique($row);
    $self->_assert_outbox_unique($row);
    $self->_assert_audit_pk_unique($row);
    $self->_assert_event_pk_unique($row);
    $self->_assert_post_id_unique($row);
    $self->_assert_post_position_unique($row);
    $self->_assert_body_id_unique($row);
    $self->_assert_revision_id_unique($row);
    $self->_assert_revision_unique($row);
    $self->_assert_credential_id_unique($row);
    $self->_assert_credential_unique($row);
    $self->_assert_session_id_unique($row);
    $self->_assert_session_hash_unique($row);
    $self->_assert_shard_unique($row);
    $self->_assert_thread_unique($row);
    $self->_assert_thread_counter_unique($row);
    $self->_assert_user_id_unique($row);
    $self->_assert_user_unique($row);

    return;
}

# DBIx::Class's context-proof form of search. lib/ calls it wherever it means a
# resultset, because search itself returns every row in list context.
sub search_rs {
    my ( $self, @arguments ) = @_;

    return $self->search(@arguments);
}

sub search {
    my ( $self, $query, $attributes ) = @_;

    $self->_assert_usable;
    $self->_record_row_lock($attributes);

    if ( $self->_skip_search ) {
        return $self->_derived_resultset( [] );
    }

    my @rows = grep { _matches_query( $_, $query ) } @{ $self->_search_rows };
    @rows = GPForum::Test::Query::ordered_rows( \@rows, $attributes );
    @rows = GPForum::Test::Query::windowed_rows( \@rows, $attributes );

    return $self->_derived_resultset( \@rows );
}

sub _derived_resultset {
    my ( $self, $rows ) = @_;

    return ref($self)->new(
        schema => $self->schema,
        name   => $self->name,
        rows   => $rows,
    );
}

sub _record_row_lock {
    my ( $self, $attributes ) = @_;

    if ( !$attributes || !defined $attributes->{for} ) {
        return;
    }
    if ( $attributes->{for} ne 'update' ) {
        return;
    }
    if ( !$self->schema->can('row_locks') ) {
        return;
    }

    $self->schema->row_locks( $self->schema->row_locks + 1 );

    return;
}

sub all {
    my ($self) = @_;

    return if !$self->rows;

    return @{ $self->rows };
}

sub single {
    my ($self) = @_;

    return if !$self->rows || !@{ $self->rows };

    return $self->rows->[0];
}

sub _search_rows {
    my ($self) = @_;

    if ( $self->_has_storage_rows ) {
        return $self->_storage_rows;
    }

    return [];
}

sub _find_user {
    my ( $self, $query ) = @_;

    return
         _find_user_row( $self, $query )
      || _find_username( $self, $query )
      || _find_email( $self, $query );
}

sub _find_user_row {
    my ( $self, $query ) = @_;

    for my $row ( @{ $self->schema->users } ) {
        return $row if _matches_query( $row, $query );
    }

    return;
}

sub _find_session {
    my ( $self, $query ) = @_;

    for my $row ( @{ $self->schema->sessions } ) {
        return $row if _matches_query( $row, $query );
    }

    return;
}

sub _find_username {
    my ( $self, $query ) = @_;

    return if !exists $query->{username};

    return $self->schema->existing_usernames->{ $query->{username} } ? 1 : 0;
}

sub _find_email {
    my ( $self, $query ) = @_;

    return if !exists $query->{email_normalized};

    return $self->schema->existing_emails->{ $query->{email_normalized} }
      ? 1
      : 0;
}

sub _find_storage_row {
    my ( $self, $query ) = @_;

    return if !$self->_has_storage_rows;

    my $criteria =
      ref $query eq 'HASH' ? $query : { _identity_key($self) => $query };

    for my $row ( @{ $self->_storage_rows } ) {
        return $row if _matches_query( $row, $criteria );
    }

    return;
}

sub _identity_key {
    my ($self) = @_;

    if ( $self->name eq 'Post' ) {
        return 'post_id';
    }
    if ( $self->name eq 'Thread' ) {
        return 'thread_id';
    }

    return 'id';
}

sub _matches_query {
    my ( $row, $query ) = @_;

    return GPForum::Test::Query::matches( $row, $query );
}

sub _skip_search {
    my ($self) = @_;

    if ( !$self->schema->can('skip_search_count') ) {
        return 0;
    }

    my $skips = $self->schema->skip_search_count;
    if ( !$skips ) {
        return 0;
    }

    $self->schema->skip_search_count( $skips - 1 );

    return 1;
}

sub _consume_find_miss {
    my ($self) = @_;

    if ( !_find_miss_resultset($self) ) {
        return 0;
    }
    if ( !$self->schema->can('find_misses') ) {
        return 0;
    }
    if ( !$self->schema->find_misses ) {
        return 0;
    }

    $self->schema->find_misses( $self->schema->find_misses - 1 );

    return 1;
}

sub _find_miss_resultset {
    my ($self) = @_;

    if ( $self->name eq 'User' ) {
        return 1;
    }
    if ( $self->name eq 'EventLog' ) {
        return 1;
    }

    return $self->name eq 'ThreadCounterShard' ? 1 : 0;
}

sub _assert_user_id_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'User' ) {
        return;
    }
    if ( _user_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('users_pkey');
    }

    return;
}

sub _assert_user_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'User' ) {
        return;
    }
    if ( $self->_user_key_taken($row) ) {
        GPForum::Infrastructure::UniqueConflict->throw('users_username_key');
    }

    return;
}

sub _user_id_taken {
    my ( $self, $row ) = @_;

    if ( !_user_id_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->users || [] } ) {
        if ( _same_text( $existing->{id}, $row->{id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _user_id_row {
    my ($row) = @_;

    return defined $row->{id} && length $row->{id} ? 1 : 0;
}

sub _user_key_taken {
    my ( $self, $row ) = @_;

    for my $existing ( @{ $self->schema->users || [] } ) {
        if ( _same_user_key( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_user_key {
    my ( $existing, $row ) = @_;

    if ( _same_text( $existing->{username}, $row->{username} ) ) {
        return 1;
    }
    if ( _same_text( $existing->{email_normalized}, $row->{email_normalized} ) )
    {
        return 1;
    }

    return 0;
}

sub _same_text {
    my ( $held, $incoming ) = @_;

    if ( !defined $held || !defined $incoming ) {
        return 0;
    }

    return $held eq $incoming ? 1 : 0;
}

sub _assert_command_id_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'CommandLog' ) {
        return;
    }
    if ( _command_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('command_log_pkey');
    }

    return;
}

sub _assert_command_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'CommandLog' ) {
        return;
    }
    if ( _command_key_taken( $self, $row->{idempotency_key} ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'command_log_idempotency_key_key');
    }

    return;
}

sub _assert_outbox_id_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'OutboxMessage' ) {
        return;
    }
    if ( _outbox_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('outbox_messages_pkey');
    }

    return;
}

sub _assert_outbox_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'OutboxMessage' ) {
        return;
    }
    if ( _outbox_key_taken( $self, $row->{idempotency_key} ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'outbox_messages_idempotency_key_key');
    }

    return;
}

sub _assert_audit_pk_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'AuditLog' ) {
        return;
    }
    if ( _audit_pk_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('audit_log_pkey');
    }

    return;
}

sub _assert_event_pk_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'EventLog' ) {
        return;
    }
    if ( _event_pk_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('event_log_pkey');
    }

    return;
}

sub _assert_post_id_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'Post' ) {
        return;
    }
    if ( _post_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('posts_pkey');
    }

    return;
}

sub _assert_post_position_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'Post' ) {
        return;
    }
    if ( _post_position_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'posts_thread_position_key');
    }

    return;
}

sub _assert_body_id_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'PostBody' ) {
        return;
    }
    if ( _body_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('post_bodies_pkey');
    }

    return;
}

sub _assert_revision_id_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'PostRevision' ) {
        return;
    }
    if ( _revision_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('post_revisions_pkey');
    }

    return;
}

sub _assert_revision_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'PostRevision' ) {
        return;
    }
    if ( _revision_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'post_revisions_post_revision_number_key');
    }

    return;
}

sub _assert_credential_id_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'Credential' ) {
        return;
    }
    if ( _credential_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('credentials_pkey');
    }

    return;
}

sub _assert_credential_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'Credential' ) {
        return;
    }
    if ( _active_password_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'idx_credentials_active_password_unique');
    }

    return;
}

sub _assert_session_id_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'Session' ) {
        return;
    }
    if ( _session_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('sessions_pkey');
    }

    return;
}

sub _assert_session_hash_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'Session' ) {
        return;
    }
    if ( _session_hash_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'sessions_session_hash_key');
    }

    return;
}

sub _assert_shard_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'ThreadCounterShard' ) {
        return;
    }
    if ( _shard_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'thread_counter_shards_pkey');
    }

    return;
}

sub _assert_thread_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'Thread' ) {
        return;
    }
    if ( _thread_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('threads_pkey');
    }

    return;
}

sub _assert_thread_counter_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'ThreadCounter' ) {
        return;
    }
    if ( _thread_counter_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('thread_counters_pkey');
    }

    return;
}

sub _assert_token_id_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'IdentityToken' ) {
        return;
    }
    if ( _token_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('identity_tokens_pkey');
    }

    return;
}

sub _assert_open_token_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'IdentityToken' ) {
        return;
    }
    if ( $self->_open_token_taken($row) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'idx_identity_tokens_open_user_type');
    }

    return;
}

sub _assert_token_hash_unique {
    my ( $self, $row ) = @_;

    if ( $self->name ne 'IdentityToken' ) {
        return;
    }
    if ( _token_hash_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'identity_tokens_hash_key');
    }

    return;
}

sub _open_token_taken {
    my ( $self, $row ) = @_;

    if ( !_open_token_row($row) ) {
        return 0;
    }

    return _open_token_exists( $self->schema->identity_tokens || [], $row );
}

sub _open_token_row {
    my ($row) = @_;

    if ( !$row->{user_id} ) {
        return 0;
    }
    if ( defined $row->{used_at} ) {
        return 0;
    }

    return 1;
}

sub _open_token_exists {
    my ( $tokens, $row ) = @_;

    for my $existing ( @{$tokens} ) {
        if ( _same_open_token( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_open_token {
    my ( $existing, $row ) = @_;

    if ( !_open_token_row($existing) ) {
        return 0;
    }

    return _same_open_token_key( $existing, $row );
}

sub _same_open_token_key {
    my ( $existing, $row ) = @_;

    if ( ( $existing->{user_id} || q{} ) ne $row->{user_id} ) {
        return 0;
    }
    if ( ( $existing->{token_type} || q{} ) ne $row->{token_type} ) {
        return 0;
    }

    return 1;
}

sub _token_id_taken {
    my ( $self, $row ) = @_;

    if ( !_token_id_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->identity_tokens || [] } ) {
        if ( _same_text( $existing->{token_id}, $row->{token_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _token_id_row {
    my ($row) = @_;

    return defined $row->{token_id} && length $row->{token_id} ? 1 : 0;
}

sub _token_hash_taken {
    my ( $self, $row ) = @_;

    if ( !_token_hash_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->identity_tokens || [] } ) {
        if ( _same_text( $existing->{token_hash}, $row->{token_hash} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _token_hash_row {
    my ($row) = @_;

    return defined $row->{token_hash} && length $row->{token_hash} ? 1 : 0;
}

sub _command_id_taken {
    my ( $self, $row ) = @_;

    if ( !_command_id_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->command_logs || [] } ) {
        if ( _same_text( $existing->{command_id}, $row->{command_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _command_id_row {
    my ($row) = @_;

    return defined $row->{command_id} && length $row->{command_id} ? 1 : 0;
}

sub _command_key_taken {
    my ( $self, $key ) = @_;

    if ( !defined $key ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->command_logs } ) {
        if ( ( $existing->{idempotency_key} || q{} ) eq $key ) {
            return 1;
        }
    }

    return 0;
}

sub _outbox_id_taken {
    my ( $self, $row ) = @_;

    if ( !_outbox_id_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->outbox_messages || [] } ) {
        if ( _same_text( $existing->{outbox_id}, $row->{outbox_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _outbox_id_row {
    my ($row) = @_;

    return defined $row->{outbox_id} && length $row->{outbox_id} ? 1 : 0;
}

sub _outbox_key_taken {
    my ( $self, $key ) = @_;

    if ( !defined $key ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->outbox_messages } ) {
        if ( ( $existing->{idempotency_key} || q{} ) eq $key ) {
            return 1;
        }
    }

    return 0;
}

sub _audit_pk_taken {
    my ( $self, $row ) = @_;

    if ( !_audit_pk_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->audit_logs || [] } ) {
        if ( !_same_audit_pk( $existing, $row ) ) {
            next;
        }
        return 1;
    }

    return 0;
}

sub _audit_pk_row {
    my ($row) = @_;

    if ( !defined $row->{audit_id} || !length $row->{audit_id} ) {
        return 0;
    }

    return defined $row->{created_at} && length $row->{created_at} ? 1 : 0;
}

sub _same_audit_pk {
    my ( $existing, $row ) = @_;

    if ( !_same_text( $existing->{audit_id}, $row->{audit_id} ) ) {
        return 0;
    }

    return _same_text( $existing->{created_at}, $row->{created_at} );
}

sub _event_pk_taken {
    my ( $self, $row ) = @_;

    if ( !_event_pk_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->event_logs || [] } ) {
        if ( !_same_event_pk( $existing, $row ) ) {
            next;
        }
        return 1;
    }

    return 0;
}

sub _event_pk_row {
    my ($row) = @_;

    if ( !defined $row->{event_id} || !length $row->{event_id} ) {
        return 0;
    }

    return defined $row->{created_at} && length $row->{created_at} ? 1 : 0;
}

sub _same_event_pk {
    my ( $existing, $row ) = @_;

    if ( !_same_text( $existing->{event_id}, $row->{event_id} ) ) {
        return 0;
    }

    return _same_text( $existing->{created_at}, $row->{created_at} );
}

sub _post_id_taken {
    my ( $self, $row ) = @_;

    if ( !_post_id_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->posts || [] } ) {
        if ( _same_text( $existing->{post_id}, $row->{post_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _post_id_row {
    my ($row) = @_;

    return defined $row->{post_id} && length $row->{post_id} ? 1 : 0;
}

sub _post_position_taken {
    my ( $self, $row ) = @_;

    if ( !_post_position_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->posts || [] } ) {
        if ( _same_post_position( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _post_position_row {
    my ($row) = @_;

    if ( !defined $row->{thread_id} || !length $row->{thread_id} ) {
        return 0;
    }

    return defined $row->{position} ? 1 : 0;
}

sub _same_post_position {
    my ( $existing, $row ) = @_;

    if ( !_same_text( $existing->{thread_id}, $row->{thread_id} ) ) {
        return 0;
    }

    return _same_text( $existing->{position}, $row->{position} );
}

sub _body_id_taken {
    my ( $self, $row ) = @_;

    if ( !_body_id_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->post_bodies || [] } ) {
        if ( _same_text( $existing->{body_id}, $row->{body_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _body_id_row {
    my ($row) = @_;

    return defined $row->{body_id} && length $row->{body_id} ? 1 : 0;
}

sub _revision_id_taken {
    my ( $self, $row ) = @_;

    if ( !_revision_id_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->post_revisions || [] } ) {
        if ( _same_text( $existing->{revision_id}, $row->{revision_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _revision_id_row {
    my ($row) = @_;

    return defined $row->{revision_id} && length $row->{revision_id} ? 1 : 0;
}

sub _revision_taken {
    my ( $self, $row ) = @_;

    if ( !_revision_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->post_revisions || [] } ) {
        if ( _same_revision( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _revision_row {
    my ($row) = @_;

    if ( !defined $row->{post_id} || !length $row->{post_id} ) {
        return 0;
    }

    return defined $row->{revision_number} ? 1 : 0;
}

sub _same_revision {
    my ( $existing, $row ) = @_;

    if ( !_same_text( $existing->{post_id}, $row->{post_id} ) ) {
        return 0;
    }

    return _same_text( $existing->{revision_number}, $row->{revision_number} );
}

sub _credential_id_taken {
    my ( $self, $row ) = @_;

    if ( !_credential_id_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->credentials || [] } ) {
        if ( _same_text( $existing->{id}, $row->{id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _credential_id_row {
    my ($row) = @_;

    return defined $row->{id} && length $row->{id} ? 1 : 0;
}

sub _active_password_taken {
    my ( $self, $row ) = @_;

    if ( !_active_password_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->credentials || [] } ) {
        if ( _same_active_password( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value ? 1 : 0;
}

sub _active_password_row {
    my ($row) = @_;

    if ( ( $row->{type} || q{} ) ne 'password' ) {
        return 0;
    }
    if ( _has_text( $row->{revoked_at} ) ) {
        return 0;
    }

    return _has_text( $row->{user_id} );
}

sub _same_active_password {
    my ( $existing, $row ) = @_;

    if ( !_active_password_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{user_id}, $row->{user_id} );
}

sub _session_id_taken {
    my ( $self, $row ) = @_;

    if ( !_session_id_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->sessions || [] } ) {
        if ( _same_text( $existing->{session_id}, $row->{session_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _session_id_row {
    my ($row) = @_;

    return defined $row->{session_id} && length $row->{session_id} ? 1 : 0;
}

sub _session_hash_taken {
    my ( $self, $row ) = @_;

    if ( !_session_hash_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->sessions || [] } ) {
        if ( _same_text( $existing->{session_hash}, $row->{session_hash} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _session_hash_row {
    my ($row) = @_;

    return defined $row->{session_hash} && length $row->{session_hash} ? 1 : 0;
}

sub _shard_taken {
    my ( $self, $row ) = @_;

    if ( !_shard_row($row) ) {
        return 0;
    }

    for my $existing ( @{ $self->schema->thread_counter_shards || [] } ) {
        if ( _same_shard( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _thread_taken {
    my ( $self, $row ) = @_;

    for my $existing ( @{ $self->schema->threads || [] } ) {
        if ( _same_text( $existing->{thread_id}, $row->{thread_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _thread_counter_taken {
    my ( $self, $row ) = @_;

    for my $existing ( @{ $self->schema->thread_counters || [] } ) {
        if ( _same_text( $existing->{thread_id}, $row->{thread_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _shard_row {
    my ($row) = @_;

    if ( !defined $row->{thread_id} || !length $row->{thread_id} ) {
        return 0;
    }

    return defined $row->{shard_id} ? 1 : 0;
}

sub _same_shard {
    my ( $existing, $row ) = @_;

    if ( !_same_text( $existing->{thread_id}, $row->{thread_id} ) ) {
        return 0;
    }

    return _same_text( $existing->{shard_id}, $row->{shard_id} );
}

sub _has_storage_rows {
    my ($self) = @_;

    return exists $STORAGE_ACCESSOR_FOR{ $self->name } ? 1 : 0;
}

sub _storage_rows {
    my ($self) = @_;

    my $accessor = $STORAGE_ACCESSOR_FOR{ $self->name };
    return $self->schema->$accessor if $accessor;

    return [];
}

1;
