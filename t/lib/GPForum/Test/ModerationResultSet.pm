package GPForum::Test::ModerationResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::ModerationRow;
use GPForum::Test::ModerationSearch;

our $VERSION = '0.001';

has created    => sub { return []; };
has rows       => sub { return {}; };
has last_query => sub { return {}; };
has last_attrs => sub { return {}; };

sub create {
    my ( $self, $row ) = @_;

    my $object = GPForum::Test::ModerationRow->new( data => $row );
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

    return GPForum::Test::ModerationSearch->new( rows => \@rows );
}

sub _store_row {
    my ( $self, $row, $object ) = @_;

    for my $key ( _row_keys($row) ) {
        $self->rows->{$key} = $object;
    }

    return;
}

sub _row_keys {
    my ($row) = @_;

    return grep { defined && length } (
        @{$row}{
            qw(
              report_id
              moderation_action_id
              suspension_id
              audit_id
              post_id
              thread_id
            )
        },
        _composite_key($row),
    );
}

sub _composite_key {
    my ($row) = @_;

    return join q{:},
      grep { defined } @{$row}{qw(target_type target_id status)};
}

1;
