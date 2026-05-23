package GPForum::Test::NotificationResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::NotificationRow;
use GPForum::Test::NotificationSearch;

our $VERSION = '0.001';

has created    => sub { return []; };
has rows       => sub { return {}; };
has last_query => sub { return {}; };
has last_attrs => sub { return {}; };

sub create {
    my ( $self, $row ) = @_;

    my $object = GPForum::Test::NotificationRow->new( data => $row );
    push @{ $self->created }, $row;
    $self->_store_row( $row, $object );

    return $object;
}

sub update_or_create {
    my ( $self, $row ) = @_;

    return $self->create($row);
}

sub find {
    my ( $self, $query ) = @_;

    my $key = ref $query eq 'HASH' ? _composite_key($query) : $query;

    return $self->rows->{$key};
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->last_query($query);
    $self->last_attrs( $attrs || {} );

    my %seen;
    my @rows = grep { !$seen{ 0 + $_ }++ } values %{ $self->rows };

    return GPForum::Test::NotificationSearch->new( rows => \@rows, );
}

sub _store_row {
    my ( $self, $row, $object ) = @_;

    my $key =
         $row->{subscription_id}
      || $row->{notification_id}
      || $row->{user_id}
      || _composite_key($row);
    $self->rows->{$key} = $object;
    $self->rows->{ _composite_key($row) } = $object;

    return;
}

sub _composite_key {
    my ($row) = @_;

    return join q{:},
      grep { defined }
      @{$row}{qw(user_id channel recipient_user_id notification_id)};
}

1;
