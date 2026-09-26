# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SearchEventRecorder;

use strict;
use warnings;

use List::Util qw(any);
use Mojo::Base -base;

use GPForum::Test::TransactionalSchema;

our $VERSION = '0.001';

# The events recorded, in order, as record_event was given them.
has events => sub { return []; };
has schema => sub { return GPForum::Test::TransactionalSchema->new; };

sub event_recorded {
    my ( $self, $idempotency_key ) = @_;

    return ( any { $_->{idempotency_key} eq $idempotency_key }
          @{ $self->events } ) ? 1 : 0;
}

sub record_event {
    my ( $self, %input ) = @_;

    my $event =
      { %input, event_id => 'recorded-' . ( 1 + @{ $self->events } ) };
    push @{ $self->events }, $event;

    return $event;
}

1;

__END__

=head1 NAME

GPForum::Test::SearchEventRecorder - An in-memory event recorder for the
search handler's tests.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $recorder = GPForum::Test::SearchEventRecorder->new;
    $recorder->record_event( event_type => 'x', idempotency_key => 'k' );
    $recorder->event_recorded('k');    # 1

=head1 DESCRIPTION

The part of L<GPForum::Infrastructure::EventRecorder> the search handler
uses to record the next batch of a thread's posts: C<event_recorded>,
C<record_event>, and a C<schema> whose C<txn_do> wraps the two.

=head1 SUBROUTINES/METHODS

=head2 event_recorded

True when an event with this idempotency key was recorded.

=head2 record_event

Keeps the event, with an event id of its own, and returns it.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<GPForum::Test::TransactionalSchema>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

No outbox rows: the events are the record.

=head1 AUTHOR

Giacomo Picchiarelli

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Giacomo Picchiarelli. BSD-3-Clause.

=cut
