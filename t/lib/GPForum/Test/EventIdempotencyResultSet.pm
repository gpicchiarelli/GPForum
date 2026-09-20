package GPForum::Test::EventIdempotencyResultSet;

use strict;
use warnings;

use Carp qw(croak);
use GPForum::Infrastructure::UniqueConflict;
use Mojo::Base -base;

our $VERSION = '0.001';

has fail_error => undef;
has rows       => sub { return {}; };

sub find {
    my ( $self, $query ) = @_;

    return $self->rows->{ _lookup_key($query) };
}

sub create {
    my ( $self, $row ) = @_;

    if ( defined $self->fail_error ) {
        croak $self->fail_error;
    }

    my $key = $row->{idempotency_key};
    if ( exists $self->rows->{$key} ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'event_idempotency_keys_pkey');
    }

    $self->rows->{$key} = $row;

    return $row;
}

sub _lookup_key {
    my ($query) = @_;

    if ( ref $query eq 'HASH' ) {
        return $query->{idempotency_key};
    }

    return $query;
}

1;
