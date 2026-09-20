package GPForum::Service::Forum::ReadState;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $INITIAL_POSITION    => 0;
const my $STATE_ID_CONSTRAINT => 'thread_read_state_pkey';
const my $DELTA_ID_CONSTRAINT => 'user_read_marker_deltas_pkey';

has clock  => sub { return GPForum::Service::Clock->new; };
has schema => undef;

sub state_for_thread {
    my ( $self, $user_id, $thread_id ) = @_;

    return _empty_state( $user_id, $thread_id )
      if !_has_value($user_id) || !_has_value($thread_id);

    my $row =
      $self->schema->resultset('ThreadReadState')
      ->find( { user_id => $user_id, thread_id => $thread_id } );

    return _empty_state( $user_id, $thread_id ) if !$row;

    return _state_from_row($row);
}

sub summary_for_page {
    my ( $self, $user_id, $thread_id, $posts ) = @_;

    my $state = $self->state_for_thread( $user_id, $thread_id );
    return {
        %{$state},
        authenticated         => _has_value($user_id) ? 1 : 0,
        first_unread_anchor   => undef,
        first_unread_position => undef,
        first_unread_post_id  => undef,
        last_visible_position => _last_visible_position($posts),
        unread_in_page        => 0,
      }
      if !_has_value($user_id);

    my $first_unread =
      _first_unread_post( $posts, $state->{last_read_position} );

    return {
        %{$state},
        authenticated         => 1,
        first_unread_anchor   => _post_anchor($first_unread),
        first_unread_position => _post_position($first_unread),
        first_unread_post_id  => _post_id($first_unread),
        last_visible_position => _last_visible_position($posts),
        unread_in_page => _unread_count( $posts, $state->{last_read_position} ),
    };
}

sub mark_thread_read {
    my ( $self, $input ) = @_;

    my $errors = _validate_mark_input($input);
    if ( keys %{$errors} ) {
        return {
            errors => $errors,
            ok     => 0,
            status => 'invalid',
        };
    }

    return $self->_with_transaction(
        sub {
            return $self->_mark_thread_read($input);
        }
    );
}

sub _mark_thread_read {
    my ( $self, $input ) = @_;

    my $current =
      $self->state_for_thread( $input->{user_id}, $input->{thread_id}, );
    my $position = _max_position( $current->{last_read_position},
        $input->{last_read_position} );
    if ( _already_marked( $current, $position ) ) {
        return _skipped_marker($current);
    }

    return $self->_persist_marker(
        {
            current  => $current,
            input    => $input,
            position => $position,
        }
    );
}

sub _already_marked {
    my ( $current, $position ) = @_;

    if ( !defined $current->{last_read_at} ) {
        return 0;
    }
    if ( $position > $current->{last_read_position} ) {
        return 0;
    }

    return 1;
}

sub _skipped_marker {
    my ($current) = @_;

    return {
        advanced   => 0,
        ok         => 1,
        read_state => {
            last_read_at       => $current->{last_read_at},
            last_read_position => $current->{last_read_position},
            thread_id          => $current->{thread_id},
            user_id            => $current->{user_id},
        },
        skipped => 1,
    };
}

sub _persist_marker {
    my ( $self, $job ) = @_;

    if ( _has_marker( $job->{current} ) ) {
        return $self->_write_marker($job);
    }

    return $self->_insert_or_reuse_marker($job);
}

sub _insert_or_reuse_marker {
    my ( $self, $job ) = @_;

    my $written = eval { return $self->_insert_marker($job); };
    if ($written) {
        return $written;
    }

    return $self->_marker_after_conflict( $job, $EVAL_ERROR );
}

sub _marker_after_conflict {
    my ( $self, $job, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $current = $self->_reloaded_state($job);
    if ( _already_marked( $current, $job->{position} ) ) {
        return _skipped_marker($current);
    }

    return $self->_write_after_conflict( $current, $job, $error );
}

sub _write_after_conflict {
    my ( $self, $current, $job, $error ) = @_;

    if ( !_has_marker($current) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    $job->{current} = $current;
    return $self->_write_marker($job);
}

sub _insert_marker {
    my ( $self, $job ) = @_;

    my $read_state = $self->_marker_row($job);
    my $created    = eval { return $self->_create_state($read_state); };
    if ($created) {
        $self->_insert_or_reuse_delta($read_state);
        return _marked_result( $job, $read_state );
    }

    return $self->_state_after_conflict( $job, $EVAL_ERROR );
}

sub _create_state {
    my ( $self, $read_state ) = @_;

    $self->schema->resultset('ThreadReadState')->create($read_state);

    return $read_state;
}

sub _state_after_conflict {
    my ( $self, $job, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_state_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_reuse_or_write_state( $job, $error );
}

sub _reuse_or_write_state {
    my ( $self, $job, $error ) = @_;

    my $current = $self->_reloaded_state($job);
    if ( !_has_marker($current) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_already_marked( $current, $job->{position} ) ) {
        $job->{current} = $current;
        return $self->_write_marker($job);
    }

    $self->_insert_or_reuse_delta( _row_from_current($current) );
    return _skipped_marker($current);
}

sub _insert_or_reuse_delta {
    my ( $self, $read_state ) = @_;

    my $created = eval { return $self->_create_delta($read_state); };
    if ($created) {
        return $created;
    }

    return $self->_delta_after_conflict( $read_state, $EVAL_ERROR );
}

sub _create_delta {
    my ( $self, $read_state ) = @_;

    $self->schema->resultset('UserReadMarkerDelta')->create($read_state);

    return $read_state;
}

sub _delta_after_conflict {
    my ( $self, $read_state, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_delta_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $read_state;
}

sub _state_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $STATE_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _delta_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $DELTA_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _row_from_current {
    my ($current) = @_;

    return {
        last_read_at       => $current->{last_read_at},
        last_read_position => $current->{last_read_position},
        thread_id          => $current->{thread_id},
        user_id            => $current->{user_id},
    };
}

sub _write_marker {
    my ( $self, $job ) = @_;

    my $read_state = $self->_marker_row($job);
    $self->schema->resultset('ThreadReadState')->update_or_create($read_state);
    $self->schema->resultset('UserReadMarkerDelta')
      ->update_or_create($read_state);

    return _marked_result( $job, $read_state );
}

sub _reloaded_state {
    my ( $self, $job ) = @_;

    return $self->state_for_thread(
        $job->{input}{user_id},
        $job->{input}{thread_id},
    );
}

sub _marker_row {
    my ( $self, $job ) = @_;

    return {
        last_read_at       => $self->clock->now_iso8601,
        last_read_position => $job->{position},
        thread_id          => $job->{input}{thread_id},
        user_id            => $job->{input}{user_id},
    };
}

sub _marked_result {
    my ( $job, $read_state ) = @_;

    return {
        advanced   => _advanced( $job->{current}, $job->{position} ),
        ok         => 1,
        read_state => $read_state,
    };
}

sub _has_marker {
    my ($current) = @_;

    if ( !$current ) {
        return 0;
    }

    return defined $current->{last_read_at} ? 1 : 0;
}

sub _advanced {
    my ( $current, $position ) = @_;

    return $position > $current->{last_read_position} ? 1 : 0;
}

sub _with_transaction {
    my ( $self, $code ) = @_;

    return $self->schema->txn_do($code)
      if $self->schema->can('txn_do');

    return $code->();
}

sub _validate_mark_input {
    my ($input) = @_;

    my %errors;
    _set_required_error( \%errors, $input, 'user_id' );
    _set_required_error( \%errors, $input, 'thread_id' );

    if ( !_valid_position( $input->{last_read_position} ) ) {
        $errors{last_read_position} =
          'last_read_position must be a non-negative integer';
    }

    return \%errors;
}

sub _set_required_error {
    my ( $errors, $input, $field ) = @_;

    if ( !_has_value( $input->{$field} ) ) {
        $errors->{$field} = "$field is required";
    }

    return;
}

sub _valid_position {
    my ($value) = @_;

    return 0 if !defined $value;
    return $value =~ /\A [[:digit:]]+ \z/msx ? 1 : 0;
}

sub _empty_state {
    my ( $user_id, $thread_id ) = @_;

    return {
        user_id            => $user_id,
        thread_id          => $thread_id,
        last_read_position => $INITIAL_POSITION,
        last_read_at       => undef,
    };
}

sub _state_from_row {
    my ($row) = @_;

    return {
        user_id            => _column( $row, 'user_id' ),
        thread_id          => _column( $row, 'thread_id' ),
        last_read_position => _column( $row, 'last_read_position' ),
        last_read_at       => _column( $row, 'last_read_at' ),
    };
}

sub _first_unread_post {
    my ( $posts, $last_read_position ) = @_;

    for my $post ( @{$posts} ) {
        return $post if _post_position($post) > $last_read_position;
    }

    return;
}

sub _unread_count {
    my ( $posts, $last_read_position ) = @_;

    my $count = 0;
    for my $post ( @{$posts} ) {
        if ( _post_position($post) > $last_read_position ) {
            $count += 1;
        }
    }

    return $count;
}

sub _last_visible_position {
    my ($posts) = @_;

    my $last_position = $INITIAL_POSITION;
    for my $post ( @{$posts} ) {
        my $position = _post_position($post);
        if ( $position > $last_position ) {
            $last_position = $position;
        }
    }

    return $last_position;
}

sub _post_anchor {
    my ($post) = @_;

    my $post_id = _post_id($post);
    return if !defined $post_id;

    return 'post-' . $post_id;
}

sub _post_id {
    my ($post) = @_;

    return if !$post;

    return _column( $post, 'post_id' );
}

sub _post_position {
    my ($post) = @_;

    return $INITIAL_POSITION if !$post;

    return _column( $post, 'position' ) || $INITIAL_POSITION;
}

sub _max_position {
    my ( $stored_position, $requested_position ) = @_;

    return $stored_position > $requested_position
      ? $stored_position
      : $requested_position;
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    croak 'read state row does not expose columns';
}

sub _has_value {
    my ($value) = @_;

    return defined $value && length $value ? 1 : 0;
}

1;
