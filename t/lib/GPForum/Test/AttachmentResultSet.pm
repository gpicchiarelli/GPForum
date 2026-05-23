package GPForum::Test::AttachmentResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::AttachmentRow;

our $VERSION = '0.001';

has created => sub { return []; };
has rows    => sub { return {}; };

sub create {
    my ( $self, $row ) = @_;

    my $object = GPForum::Test::AttachmentRow->new( data => $row );
    push @{ $self->created }, $row;
    $self->_store_row( $row, $object );

    return $object;
}

sub find {
    my ( $self, $id ) = @_;

    return $self->rows->{$id};
}

sub _store_row {
    my ( $self, $row, $object ) = @_;

    my $key = _row_key($row);

    if ( defined $key ) {
        $self->rows->{$key} = $object;
    }

    return;
}

sub _row_key {
    my ($row) = @_;

    for my $column (
        qw(
        attachment_id
        attachment_link_id
        attachment_variant_id
        event_id
        audit_id
        outbox_id
        )
      )
    {
        return $row->{$column} if defined $row->{$column};
    }

    return;
}

1;
