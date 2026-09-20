package GPForum::Worker::EventIdempotencyStore;

use strict;
use warnings;

use English qw(-no_match_vars);
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use Mojo::Base -base;

our $VERSION = '0.001';

has clock  => sub { return GPForum::Service::Clock->new; };
has schema => undef;

sub is_done {
    my ( $self, $key ) = @_;

    if ( $self->_find($key) ) {
        return 1;
    }

    return 0;
}

sub begin {
    my ( undef, $key ) = @_;

    return $key;
}

sub mark_failed {
    my ( undef, $key ) = @_;

    return $key;
}

sub mark_done {
    my ( $self, $key, $result ) = @_;

    my $ok = eval {
        $self->_insert( $key, $result );
        return 1;
    };
    if ($ok) {
        return 1;
    }

    return $self->_accept_conflict($EVAL_ERROR);
}

sub _accept_conflict {
    my ( undef, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return 1;
}

sub _insert {
    my ( $self, $key, $result ) = @_;

    $self->_resultset->create(
        {
            created_at      => $self->clock->now_iso8601,
            event_id        => _event_id( $key, $result ),
            idempotency_key => $key,
        }
    );

    return 1;
}

sub _find {
    my ( $self, $key ) = @_;

    return $self->_resultset->find($key);
}

sub _resultset {
    my ($self) = @_;

    return $self->schema->resultset('EventIdempotencyKey');
}

sub _event_id {
    my ( $key, $result ) = @_;

    my $from_result = _result_event_id($result);
    if ( length $from_result ) {
        return $from_result;
    }

    return _key_event_id($key);
}

sub _result_event_id {
    my ($result) = @_;

    if ( ref $result ne 'HASH' ) {
        return q{};
    }

    my $event_id = $result->{event_id};
    if ( !defined $event_id || !length $event_id ) {
        return q{};
    }

    return $event_id;
}

sub _key_event_id {
    my ($key) = @_;

    my ($event_id) = $key =~ m/:([^:]+)\z/msx;
    if ( defined $event_id && length $event_id ) {
        return $event_id;
    }

    return $key;
}

1;
