# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::ReadState;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::PreparedQuery;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::X::Argument;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $INITIAL_POSITION    => 0;
const my $STATE_ID_CONSTRAINT => 'thread_read_state_pkey';
const my $DELTA_ID_CONSTRAINT => 'user_read_marker_deltas_pkey';

__PACKAGE__->requires('schema');

has clock    => sub { return GPForum::Service::Clock->new; };
has prepared => sub { return GPForum::Infrastructure::PreparedQuery->new; };

sub state_for_thread ( $self, $user_id, $thread_id ) {
    my $row =
         _has_value($user_id)
      && _has_value($thread_id)
      ? $self->_stored_state( $user_id, $thread_id )
      : undef;
    if ( !$row ) {
        return {
            user_id            => $user_id,
            thread_id          => $thread_id,
            last_read_position => $INITIAL_POSITION,
            last_read_at       => undef,
        };
    }

    return { map { $_ => _column( $row, $_ ) }
          qw(user_id thread_id last_read_position last_read_at) };
}

# The row by its key, through a statement built once (every signed-in
# thread page reads one).
sub _stored_state ( $self, $user_id, $thread_id ) {
    my $states = $self->schema->resultset('ThreadReadState');
    my %key    = ( thread_id => $thread_id, user_id => $user_id );

    return $self->prepared->row(
        schema    => $self->schema,
        shape     => 'thread_read_state:by-key',
        source    => 'ThreadReadState',
        resultset => sub {
            return $states->search_rs(
                { map { ( "me.$_" => $key{$_} ) } sort keys %key } );
        },
        fallback => sub { return [ $states->find( \%key ) // () ]; },
        values   => { map { ( "me.$_" => $key{$_} ) } keys %key },
    );
}

sub summary_for_page ( $self, $user_id, $thread_id, $posts ) {
    my $state = $self->state_for_thread( $user_id, $thread_id );
    if ( !_has_value($user_id) ) {
        return {
            %{$state},
            authenticated         => 0,
            first_unread_anchor   => undef,
            first_unread_position => undef,
            first_unread_post_id  => undef,
            last_visible_position => _last_visible_position($posts),
            unread_in_page        => 0,
        };
    }

    my @unread =
      grep { _post_position($_) > $state->{last_read_position} } @{$posts};
    my $first_unread = $unread[0];
    my $first_unread_post_id =
      $first_unread ? _column( $first_unread, 'post_id' ) : undef;

    return {
        %{$state},
        authenticated       => 1,
        first_unread_anchor => defined $first_unread_post_id
        ? 'post-' . $first_unread_post_id
        : undef,
        first_unread_position => _post_position($first_unread),
        first_unread_post_id  => $first_unread_post_id,
        last_visible_position => _last_visible_position($posts),
        unread_in_page        => scalar @unread,
    };
}

sub mark_thread_read ( $self, $input ) {
    my %errors =
      map { _has_value( $input->{$_} ) ? () : ( $_ => "$_ is required" ) }
      qw(user_id thread_id);
    my $position = $input->{last_read_position};
    if ( !defined $position || $position !~ /\A [[:digit:]]+ \z/msx ) {
        $errors{last_read_position} =
          'last_read_position must be a non-negative integer';
    }
    if (%errors) {
        return {
            errors => \%errors,
            ok     => 0,
            status => 'invalid',
        };
    }

    my $mark = sub { return $self->_mark_thread_read($input); };
    return $self->schema->txn_do($mark) if $self->schema->can('txn_do');

    return $mark->();
}

# The marker only moves forward: a mark behind the stored one keeps the
# stored position, and one that would not advance it writes nothing.
sub _mark_thread_read ( $self, $input ) {
    my $current =
      $self->state_for_thread( $input->{user_id}, $input->{thread_id}, );
    my $position =
        $current->{last_read_position} > $input->{last_read_position}
      ? $current->{last_read_position}
      : $input->{last_read_position};
    if ( _already_marked( $current, $position ) ) {
        return _skipped_marker($current);
    }

    my $job = {
        current  => $current,
        input    => $input,
        position => $position,
    };
    return $self->_write_marker($job) if _has_marker($current);

    return $self->_insert_or_reuse_marker($job);
}

# A first mark. When a concurrent first mark committed the marker before this
# one could, its row is read back and advanced, or this mark is skipped.
sub _insert_or_reuse_marker ( $self, $job ) {
    my ( $written, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_marker($job); },
      );
    return $written if $written;

    if ( !GPForum::X::Conflict->caught($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    my $current = $self->_reloaded_state($job);
    if ( _already_marked( $current, $job->{position} ) ) {
        return _skipped_marker($current);
    }
    if ( !_has_marker($current) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    $job->{current} = $current;
    return $self->_write_marker($job);
}

# Inserts the marker and its delta. A collision on the marker's primary key
# means a concurrent mark inserted it inside this transaction's view: that
# row is advanced, or kept with its delta ensured.
sub _insert_marker ( $self, $job ) {
    my $read_state = $self->_marker_row($job);
    my ( $created, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            $self->schema->resultset('ThreadReadState')->create($read_state);
            return $read_state;
        },
    );
    if ($created) {
        $self->_insert_or_reuse_delta($read_state);
        return _marked_result( $job, $read_state );
    }

    if (   !GPForum::X::Conflict->caught($error)
        || !$error->on($STATE_ID_CONSTRAINT) )
    {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    my $current = $self->_reloaded_state($job);
    if ( !_has_marker($current) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_already_marked( $current, $job->{position} ) ) {
        $job->{current} = $current;
        return $self->_write_marker($job);
    }

    $self->_insert_or_reuse_delta( _read_state_of($current) );
    return _skipped_marker($current);
}

# Inserts the delta for $read_state; one already there, by its primary key,
# is kept.
sub _insert_or_reuse_delta ( $self, $read_state ) {
    my ( $created, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            $self->schema->resultset('UserReadMarkerDelta')
              ->create($read_state);
            return $read_state;
        },
    );
    return $created if $created;

    if (   !GPForum::X::Conflict->caught($error)
        || !$error->on($DELTA_ID_CONSTRAINT) )
    {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $read_state;
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
        advanced => $job->{position} > $job->{current}{last_read_position}
        ? 1
        : 0,
        ok         => 1,
        read_state => $read_state,
    };
}

sub _skipped_marker ($current) {
    return {
        advanced   => 0,
        ok         => 1,
        read_state => _read_state_of($current),
        skipped    => 1,
    };
}

sub _read_state_of ($current) {
    return {
        last_read_at       => $current->{last_read_at},
        last_read_position => $current->{last_read_position},
        thread_id          => $current->{thread_id},
        user_id            => $current->{user_id},
    };
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

sub _has_marker ($current) {
    if ( !$current ) {
        return 0;
    }

    return defined $current->{last_read_at} ? 1 : 0;
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

sub _post_position ($post) {
    return $INITIAL_POSITION if !$post;

    return _column( $post, 'position' ) || $INITIAL_POSITION;
}

sub _column ( $row, $name ) {
    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    GPForum::X::Argument->throw(
        message => 'read state row does not expose columns' );
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

=head2 new

Constructor (L<GPForum::Base>). C<schema>, the L<DBIx::Class> schema, is
required: without it C<new> throws L<GPForum::X::Argument>. C<clock>
defaults to L<GPForum::Service::Clock>.

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
propagate. Throws L<GPForum::X::Argument>
C<read state row does not expose columns> for a post or row that is neither
a hash nor has C<get_column>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Base>, L<GPForum::Infrastructure::UniqueConflict>,
L<GPForum::Service::Clock>, L<GPForum::X::Argument>, L<GPForum::X::Conflict>.

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
