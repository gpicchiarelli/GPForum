package GPForum::Test::ReadStateResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::ReadStateRow;

our $VERSION = '0.001';

has created     => sub { return []; };
has find_misses => 0;
has rows        => sub { return {}; };
has unique_name => sub { return 'thread_read_state_pkey'; };

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_unique($row);
    my $object = GPForum::Test::ReadStateRow->new( data => { %{$row} } );
    $self->rows->{ _key($row) } = $object;
    push @{ $self->created }, { %{$row} };

    return $object;
}

sub update_or_create {
    my ( $self, $row ) = @_;

    my $existing = $self->rows->{ _key($row) };
    if ($existing) {
        return $existing->update($row);
    }

    return $self->create($row);
}

sub find {
    my ( $self, $query ) = @_;

    if ( $self->find_misses ) {
        $self->find_misses( $self->find_misses - 1 );
        return;
    }

    return $self->rows->{ _key($query) };
}

sub _assert_unique {
    my ( $self, $row ) = @_;

    my $key = _key($row);
    if ( $key && $self->rows->{$key} ) {
        GPForum::Infrastructure::UniqueConflict->throw( $self->unique_name );
    }

    return;
}

sub _key {
    my ($row) = @_;

    return join q{:}, @{$row}{qw(user_id thread_id)};
}

1;
