package GPForum::Test::EngineeringCorrectness::ResultSet;

use strict;
use warnings;

use Carp       qw(croak);
use List::Util qw(all);
use Mojo::Base -base;

use GPForum::Test::EngineeringCorrectness::Row;

our $VERSION = '0.001';

has name   => undef;
has schema => undef;

sub create {
    my ( $self, $row ) = @_;

    croak 'injected create failure for ' . $self->name
      if ( $self->schema->fail_resultset || q{} ) eq $self->name;
    $self->_assert_unique_post_position($row);

    my $stored = { %{$row} };
    push @{ $self->schema->created_for( $self->name ) }, $stored;

    return GPForum::Test::EngineeringCorrectness::Row->new( data => $stored );
}

sub find {
    my ( $self, $query ) = @_;

    for my $stored ( @{ $self->schema->created_for( $self->name ) } ) {
        if ( all { _same_value( $stored->{$_}, $query->{$_} ) } keys %{$query} )
        {
            return GPForum::Test::EngineeringCorrectness::Row->new(
                data => $stored );
        }
    }

    return;
}

sub _same_value {
    my ( $stored_value, $query_value ) = @_;

    return ( $stored_value // q{} ) eq ( $query_value // q{} ) ? 1 : 0;
}

sub _assert_unique_post_position {
    my ( $self, $row ) = @_;

    return if !$self->schema->unique_post_positions;
    return if $self->name ne 'Post';

    my $key = join q{:}, @{$row}{qw(thread_id position)};
    croak 'duplicate post position'
      if $self->schema->post_positions->{$key};

    $self->schema->post_positions->{$key} = 1;

    return;
}

1;
