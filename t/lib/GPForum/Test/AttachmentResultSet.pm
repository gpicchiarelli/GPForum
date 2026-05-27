package GPForum::Test::AttachmentResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::AttachmentRow;

our $VERSION = '0.001';

has created    => sub { return []; };
has last_attrs => sub { return {}; };
has last_query => sub { return {}; };
has rows       => sub { return {}; };

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

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->last_query( $query || {} );
    $self->last_attrs( $attrs || {} );

    my @rows = values %{ $self->rows };
    my %seen;
    @rows = grep { !$seen{ 0 + $_ }++ } @rows;
    @rows = grep { _matches_query( $_, $query || {} ) } @rows;

    return GPForum::Test::AttachmentSearch->new( rows => \@rows );
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
        post_id
        thread_id
        )
      )
    {
        return $row->{$column} if defined $row->{$column};
    }

    return;
}

sub _matches_query {
    my ( $row, $query ) = @_;

    for my $field ( keys %{$query} ) {
        return if !_matches_field( $row, $field, $query->{$field} );
    }

    return 1;
}

sub _matches_field {
    my ( $row, $field, $expected ) = @_;

    my $actual = $row->get_column($field);
    if ( ref $expected eq 'HASH' && exists $expected->{-in} ) {
        my %allowed = map { $_ => 1 } @{ $expected->{-in} };
        return $allowed{$actual} ? 1 : 0;
    }

    return !defined $actual if !defined $expected;

    return defined $actual && $actual eq $expected ? 1 : 0;
}

package GPForum::Test::AttachmentSearch;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has rows => sub { return []; };

sub all {
    my ($self) = @_;

    return @{ $self->rows };
}

sub single {
    my ($self) = @_;

    return $self->rows->[0];
}

1;
