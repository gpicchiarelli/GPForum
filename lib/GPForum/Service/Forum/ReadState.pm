# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::ReadState;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $INITIAL_POSITION    => 0;
const my $STATE_ID_CONSTRAINT => 'thread_read_state_pkey';
const my $DELTA_ID_CONSTRAINT => 'user_read_marker_deltas_pkey';

has clock  => sub { return GPForum::Service::Clock->new; };
has schema => undef;

sub state_for_thread ( $self, $user_id, $thread_id ) {
    return _empty_state( $user_id, $thread_id )
      if !_has_value($user_id) || !_has_value($thread_id);

    my $row =
      $self->schema->resultset('ThreadReadState')
      ->find( { user_id => $user_id, thread_id => $thread_id } );

    return _empty_state( $user_id, $thread_id ) if !$row;

    return _state_from_row($row);
}

sub summary_for_page ( $self, $user_id, $thread_id, $posts ) {
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

sub mark_thread_read ( $self, $input ) {
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

sub _mark_thread_read ( $self, $input ) {
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

sub _already_marked ( $current, $position ) {
    if ( !defined $current->{last_read_at} ) {
        return 0;
    }
    if ( $position > $current->{last_read_position} ) {
        return 0;
    }

    return 1;
}

sub _skipped_marker ($current) {
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

sub _persist_marker ( $self, $job ) {
    if ( _has_marker( $job->{current} ) ) {
        return $self->_write_marker($job);
    }

    return $self->_insert_or_reuse_marker($job);
}

sub _insert_or_reuse_marker ( $self, $job ) {
    my ( $written, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_marker($job); },
      );
    if ($written) {
        return $written;
    }

    return $self->_marker_after_conflict( $job, $error );
}

sub _marker_after_conflict ( $self, $job, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $current = $self->_reloaded_state($job);
    if ( _already_marked( $current, $job->{position} ) ) {
        return _skipped_marker($current);
    }

    return $self->_write_after_conflict( $current, $job, $error );
}

sub _write_after_conflict ( $self, $current, $job, $error ) {
    if ( !_has_marker($current) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    $job->{current} = $current;
    return $self->_write_marker($job);
}

sub _insert_marker ( $self, $job ) {
    my $read_state = $self->_marker_row($job);
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_state($read_state); },
      );
    if ($created) {
        $self->_insert_or_reuse_delta($read_state);
        return _marked_result( $job, $read_state );
    }

    return $self->_state_after_conflict( $job, $error );
}

sub _create_state ( $self, $read_state ) {
    $self->schema->resultset('ThreadReadState')->create($read_state);

    return $read_state;
}

sub _state_after_conflict ( $self, $job, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_state_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_reuse_or_write_state( $job, $error );
}

sub _reuse_or_write_state ( $self, $job, $error ) {
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

sub _insert_or_reuse_delta ( $self, $read_state ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_delta($read_state); },
      );
    if ($created) {
        return $created;
    }

    return $self->_delta_after_conflict( $read_state, $error );
}

sub _create_delta ( $self, $read_state ) {
    $self->schema->resultset('UserReadMarkerDelta')->create($read_state);

    return $read_state;
}

sub _delta_after_conflict ( $self, $read_state, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_delta_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $read_state;
}

sub _state_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $STATE_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _delta_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $DELTA_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _row_from_current ($current) {
    return {
        last_read_at       => $current->{last_read_at},
        last_read_position => $current->{last_read_position},
        thread_id          => $current->{thread_id},
        user_id            => $current->{user_id},
    };
}

sub _write_marker ( $self, $job ) {
    my $read_state = $self->_marker_row($job);
    $self->schema->resultset('ThreadReadState')->update_or_create($read_state);
    $self->schema->resultset('UserReadMarkerDelta')
      ->update_or_create($read_state);

    return _marked_result( $job, $read_state );
}

sub _reloaded_state ( $self, $job ) {
    return $self->state_for_thread(
        $job->{input}{user_id},
        $job->{input}{thread_id},
    );
}

sub _marker_row ( $self, $job ) {
    return {
        last_read_at       => $self->clock->now_iso8601,
        last_read_position => $job->{position},
        thread_id          => $job->{input}{thread_id},
        user_id            => $job->{input}{user_id},
    };
}

sub _marked_result ( $job, $read_state ) {
    return {
        advanced   => _advanced( $job->{current}, $job->{position} ),
        ok         => 1,
        read_state => $read_state,
    };
}

sub _has_marker ($current) {
    if ( !$current ) {
        return 0;
    }

    return defined $current->{last_read_at} ? 1 : 0;
}

sub _advanced ( $current, $position ) {
    return $position > $current->{last_read_position} ? 1 : 0;
}

sub _with_transaction ( $self, $code ) {
    return $self->schema->txn_do($code)
      if $self->schema->can('txn_do');

    return $code->();
}

sub _validate_mark_input ($input) {
    my %errors;
    _set_required_error( \%errors, $input, 'user_id' );
    _set_required_error( \%errors, $input, 'thread_id' );

    if ( !_valid_position( $input->{last_read_position} ) ) {
        $errors{last_read_position} =
          'last_read_position must be a non-negative integer';
    }

    return \%errors;
}

sub _set_required_error ( $errors, $input, $field ) {
    if ( !_has_value( $input->{$field} ) ) {
        $errors->{$field} = "$field is required";
    }

    return;
}

sub _valid_position ($value) {
    return 0 if !defined $value;
    return $value =~ /\A [[:digit:]]+ \z/msx ? 1 : 0;
}

sub _empty_state ( $user_id, $thread_id ) {
    return {
        user_id            => $user_id,
        thread_id          => $thread_id,
        last_read_position => $INITIAL_POSITION,
        last_read_at       => undef,
    };
}

sub _state_from_row ($row) {
    return {
        user_id            => _column( $row, 'user_id' ),
        thread_id          => _column( $row, 'thread_id' ),
        last_read_position => _column( $row, 'last_read_position' ),
        last_read_at       => _column( $row, 'last_read_at' ),
    };
}

sub _first_unread_post ( $posts, $last_read_position ) {
    for my $post ( @{$posts} ) {
        return $post if _post_position($post) > $last_read_position;
    }

    return undef;
}

sub _unread_count ( $posts, $last_read_position ) {
    my $count = 0;
    for my $post ( @{$posts} ) {
        if ( _post_position($post) > $last_read_position ) {
            $count += 1;
        }
    }

    return $count;
}

sub _last_visible_position ($posts) {
    my $last_position = $INITIAL_POSITION;
    for my $post ( @{$posts} ) {
        my $position = _post_position($post);
        if ( $position > $last_position ) {
            $last_position = $position;
        }
    }

    return $last_position;
}

sub _post_anchor ($post) {
    my $post_id = _post_id($post);
    return undef if !defined $post_id;

    return 'post-' . $post_id;
}

sub _post_id ($post) {
    return undef if !$post;

    return _column( $post, 'post_id' );
}

sub _post_position ($post) {
    return $INITIAL_POSITION if !$post;

    return _column( $post, 'position' ) || $INITIAL_POSITION;
}

sub _max_position ( $stored_position, $requested_position ) {
    return $stored_position > $requested_position
      ? $stored_position
      : $requested_position;
}

sub _column ( $row, $name ) {
    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    croak 'read state row does not expose columns';
}

sub _has_value ($value) {
    return defined $value && length $value ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::ReadState - How far a member has read a thread, and the unread posts on a page.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $read_state =
      GPForum::Service::Forum::ReadState->new( schema => $schema );

    my $summary = $read_state->summary_for_page( $user_id, $thread_id, $posts );
    # first_unread_anchor => 'post-<post_id>', unread_in_page => 3, ...

    my $marked = $read_state->mark_thread_read(
        {
            last_read_position => $summary->{last_visible_position},
            thread_id          => $thread_id,
            user_id            => $user_id,
        }
    );

=head1 DESCRIPTION

A member's read marker is the highest post position they have seen in a
thread, kept in C<thread_read_state> with a copy in
C<user_read_marker_deltas>. It only moves forward: marking an earlier
position than the stored one keeps the stored one, and a mark that would not
advance an existing marker writes nothing. A first mark inserts both rows;
when a concurrent first mark wins that insert, its row is read back and this
mark either advances it or is skipped.

=head1 SUBROUTINES/METHODS

=head2 state_for_thread

Takes a user id and a thread id. Returns
C<< { user_id, thread_id, last_read_position, last_read_at } >> from the
stored marker, or with position 0 and C<last_read_at> undef when there is
none or either id is empty.

=head2 summary_for_page

Takes a user id, a thread id and the page's posts (an array reference of
hashes or rows with C<post_id> and C<position>). Returns the read state
plus C<authenticated>, C<last_visible_position> (the highest position on the
page), C<first_unread_post_id>, C<first_unread_position> and
C<first_unread_anchor> (C<post-POST_ID>) of the first post past the marker,
and C<unread_in_page>, the number of posts past it. For an anonymous viewer
(an empty user id) C<authenticated> is 0, the first-unread fields are undef
and C<unread_in_page> is 0.

=head2 mark_thread_read

Takes a hash reference with C<user_id>, C<thread_id> and
C<last_read_position> (a non-negative integer). Returns
C<< { ok => 0, status => 'invalid', errors } >> for bad input. Otherwise,
in a transaction when the schema has C<txn_do>, returns
C<< { ok => 1, advanced, read_state } >> with the marker written, or the
stored marker with C<< skipped => 1 >> when nothing needed writing.
C<advanced> is 1 when the position moved past the stored one.

=head1 DIAGNOSTICS

C<mark_thread_read> returns the errors C<user_id is required>,
C<thread_id is required> and
C<last_read_position must be a non-negative integer>. An insert error other
than the expected primary-key collision, or a collision whose winning row
cannot be read back, is rethrown with C<croak>; other database errors
propagate. Croaks C<read state row does not expose columns> for a post or
row that is neither a hash nor has C<get_column>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
