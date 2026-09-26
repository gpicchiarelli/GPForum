# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Worker::Handler::ThreadActivity;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $POST_CREATED => 'post.created';
const my $BUMP_SQL => join q{ },
  q{UPDATE threads SET last_activity_at = greatest(last_activity_at,},
  q{?::timestamptz) WHERE thread_id = ?::uuid};

has schema => undef;

# threads.last_activity_at had no writer: the "latest activity" order of the
# home page, the category pages, the sitemap and the feed was creation order.
# A reply now moves its thread up -- here, after the reply has committed,
# because updating the thread row inside the reply's transaction would lock
# it for every reply to a busy thread. GREATEST makes the update idempotent
# and indifferent to the order replies are delivered in.
sub supports ( $, $event ) {
    return ( $event->{event_type} // q{} ) eq $POST_CREATED
      && defined _thread_id($event) ? 1 : 0;
}

sub handle ( $self, $event ) {
    my $thread_id = _thread_id($event);
    my $at =
         $event->{occurred_at}
      || $event->{timestamp}
      || _payload($event)->{created_at};
    my $bumped = $self->schema->storage->dbh_do(
        sub ( $, $dbh ) {
            return $dbh->do( $BUMP_SQL, undef, $at, $thread_id );
        }
    );

    return {
        action    => 'thread.activity',
        at        => $at,
        bumped    => 0 + ( $bumped // 0 ),
        thread_id => $thread_id,
    };
}

sub _thread_id ($event) {
    return $event->{thread_id} // _payload($event)->{thread_id};
}

sub _payload ($event) {
    return ref $event->{domain_payload} eq 'HASH'
      ? $event->{domain_payload}
      : {};
}

1;

__END__

=head1 NAME

GPForum::Worker::Handler::ThreadActivity - Move a thread up when it gets a reply.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    GPForum::Worker::Handler::ThreadActivity->new( schema => $schema )
      ->handle($post_created_event);

=head1 DESCRIPTION

Sets C<threads.last_activity_at> to a new reply's time, from the outbox's
C<post.created> event, idempotently.

=head1 SUBROUTINES/METHODS

=head2 supports

True for C<post.created> events that name their thread.

=head2 handle

Moves the thread's last activity to the event's time, never back.

=head1 DIAGNOSTICS

Dies when the database does; the outbox retries the event.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The thread moves up when the event is dispatched, seconds after the reply.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
