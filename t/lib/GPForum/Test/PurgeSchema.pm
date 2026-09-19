package GPForum::Test::PurgeSchema;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::PurgeResultSet;
use GPForum::Test::PurgeRow;

our $VERSION = '0.001';

has last_resultset => undef;
has tables         => sub { return {}; };

sub add_row {
    my ( $self, $name, $values ) = @_;

    my $row = GPForum::Test::PurgeRow->new(
        on_delete => sub { $self->remove_row( $name, $_[0] ) },
        values    => $values,
    );
    push @{ $self->rows_for($name) }, $row;

    return $row;
}

sub rows_for {
    my ( $self, $name ) = @_;

    $self->tables->{$name} ||= [];

    return $self->tables->{$name};
}

sub remove_row {
    my ( $self, $name, $row ) = @_;

    my $rows = $self->rows_for($name);
    @{$rows} = grep { $_ != $row } @{$rows};

    return;
}

sub resultset {
    my ( $self, $name ) = @_;

    my $resultset = GPForum::Test::PurgeResultSet->new(
        name   => $name,
        schema => $self,
    );
    $self->last_resultset($resultset);

    return $resultset;
}

1;
