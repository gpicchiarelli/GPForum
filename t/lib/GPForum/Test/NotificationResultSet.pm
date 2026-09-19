package GPForum::Test::NotificationResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::NotificationRow;
use GPForum::Test::NotificationSearch;

our $VERSION = '0.001';

has created     => sub { return []; };
has fail_create => 0;
has find_misses => 0;
has rows        => sub { return {}; };
has last_query  => sub { return {}; };
has last_attrs  => sub { return {}; };

sub create {
    my ( $self, $row ) = @_;

    die 'notification create failed' if $self->fail_create;
    $self->_assert_subscription_unique($row);

    my $object = GPForum::Test::NotificationRow->new( data => $row );
    push @{ $self->created }, $row;
    $self->_store_row( $row, $object );

    return $object;
}

sub update_or_create {
    my ( $self, $row ) = @_;

    my $existing = $self->find($row);
    if ($existing) {
        $existing->update($row);
        return $existing;
    }

    return $self->create($row);
}

sub find {
    my ( $self, $query ) = @_;

    if ( $self->_consume_find_miss ) {
        return;
    }

    return $self->_lookup_row($query);
}

sub _consume_find_miss {
    my ($self) = @_;

    if ( !$self->find_misses ) {
        return 0;
    }

    $self->find_misses( $self->find_misses - 1 );

    return 1;
}

sub _lookup_row {
    my ( $self, $query ) = @_;

    my $unique = ref $query eq 'HASH' ? _subscription_unique($query) : undef;
    if ( $unique && $self->rows->{$unique} ) {
        return $self->rows->{$unique};
    }

    my $key = ref $query eq 'HASH' ? _composite_key($query) : $query;

    return $self->rows->{$key};
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->last_query($query);
    $self->last_attrs( $attrs || {} );

    my %seen;
    my @rows = grep { !$seen{ 0 + $_ }++ } values %{ $self->rows };
    @rows = grep { _matches_query( $_, $query ) } @rows;

    return GPForum::Test::NotificationSearch->new( rows => \@rows, );
}

sub _assert_subscription_unique {
    my ( $self, $row ) = @_;

    my $key = _subscription_unique($row);
    if ( $key && $self->rows->{$key} ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'subscriptions_unique_target');
    }

    return;
}

sub _subscription_unique {
    my ($row) = @_;

    if ( !$row->{user_id} || !$row->{target_type} || !$row->{target_id} ) {
        return;
    }

    return join q{:}, $row->{user_id}, $row->{target_type}, $row->{target_id};
}

sub _store_row {
    my ( $self, $row, $object ) = @_;

    my $key =
         $row->{subscription_id}
      || $row->{notification_id}
      || $row->{user_id}
      || $row->{idempotency_key}
      || _composite_key($row);
    $self->rows->{$key} = $object;
    $self->rows->{ _composite_key($row) } = $object;
    $self->_index_subscription( $row, $object );

    return;
}

sub _index_subscription {
    my ( $self, $row, $object ) = @_;

    my $unique = _subscription_unique($row);
    if ($unique) {
        $self->rows->{$unique} = $object;
    }

    return;
}

sub _composite_key {
    my ($row) = @_;

    return join q{:},
      grep { defined }
      @{$row}{qw(user_id channel recipient_user_id notification_id)};
}

sub _matches_query {
    my ( $row, $query ) = @_;

    return 1 if !$query;

    for my $field ( keys %{$query} ) {
        next     if $field eq '-or' || $field eq '-and';
        return 0 if !_matches_field( $row, $field, $query->{$field} );
    }

    return 1;
}

sub _matches_field {
    my ( $row, $field, $expected ) = @_;

    my $actual = $row->get_column( _base_column($field) );

    return !defined $actual if !defined $expected;

    if ( ref $expected eq 'HASH' && exists $expected->{-in} ) {
        return _in_list( $actual, $expected->{-in} );
    }

    return defined $actual && $actual eq $expected;
}

sub _in_list {
    my ( $actual, $values ) = @_;

    return 0 if !defined $actual;

    for my $value ( @{$values} ) {
        return 1 if defined $value && $actual eq $value;
    }

    return 0;
}

sub _base_column {
    my ($field) = @_;

    ( my $column = $field ) =~ s/\A me [.]//msx;

    return $column;
}

1;
