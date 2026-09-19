package GPForum::Test::ReadStateResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::ReadStateRow;

our $VERSION = '0.001';

has created => sub { return []; };
has rows    => sub { return {}; };

sub update_or_create {
    my ( $self, $row ) = @_;

    my $key    = _key($row);
    my $object = $self->rows->{$key};
    if ($object) {
        $object->update($row);
    }
    else {
        $object = GPForum::Test::ReadStateRow->new( data => { %{$row} } );
        $self->rows->{$key} = $object;
    }

    push @{ $self->created }, { %{$row} };

    return $object;
}

sub find {
    my ( $self, $query ) = @_;

    return $self->rows->{ _key($query) };
}

sub _key {
    my ($row) = @_;

    return join q{:}, @{$row}{qw(user_id thread_id)};
}

1;
