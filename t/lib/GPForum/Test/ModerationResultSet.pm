package GPForum::Test::ModerationResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::ModerationRow;
use GPForum::Test::ModerationSearch;

our $VERSION = '0.001';

has created         => sub { return []; };
has created_objects => sub { return []; };
has rows            => sub { return {}; };
has last_query      => sub { return {}; };
has last_attrs      => sub { return {}; };
has filter_search   => 0;

sub create {
    my ( $self, $row ) = @_;

    my $object = GPForum::Test::ModerationRow->new( data => $row );
    push @{ $self->created },         $row;
    push @{ $self->created_objects }, $object;
    $self->_store_row( $row, $object );

    return $object;
}

sub update_or_create {
    my ( $self, $row ) = @_;

    return $self->create($row);
}

sub find {
    my ( $self, $query ) = @_;

    my $key = ref $query eq 'HASH' ? _find_key($query) : $query;

    return $self->rows->{$key};
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->last_query($query);
    $self->last_attrs( $attrs || {} );

    my @candidate_rows =
        @{ $self->created_objects }
      ? @{ $self->created_objects }
      : values %{ $self->rows };
    my %seen;
    my @rows = grep { !$seen{ 0 + $_ }++ } @candidate_rows;
    if ( $self->filter_search ) {
        @rows = grep { _matches_query( $_, $query ) } @rows;
    }

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
              event_id
              outbox_id
              moderation_action_id
              suspension_id
              audit_id
              role_id
              permission_id
              binding_id
              acl_id
              post_id
              thread_id
              import_job_id
              import_failure_id
              legacy_id_map_id
              export_request_id
              plugin_id
              hook_id
              plugin_failure_id
              deletion_request_id
              deletion_action_id
              erasure_job_id
              retention_hold_id
            )
        },
        _composite_key($row),
        _legacy_key($row),
    );
}

sub _composite_key {
    my ($row) = @_;

    return join q{:},
      grep { defined } @{$row}{qw(target_type target_id status)};
}

sub _find_key {
    my ($row) = @_;

    return _legacy_key($row) if exists $row->{legacy_type};

    return _composite_key($row);
}

sub _matches_query {
    my ( $row, $query ) = @_;

    return 1 if !$query || !%{$query};

    for my $field ( keys %{$query} ) {
        return if !_matches_field( $row, $field, $query->{$field} );
    }

    return 1;
}

sub _matches_field {
    my ( $row, $field, $expected ) = @_;

    my $actual = $row->get_column($field);

    return !defined $actual if !defined $expected;

    return defined $actual && $actual eq $expected;
}

sub _legacy_key {
    my ($row) = @_;

    return join q{:}, grep { defined } @{$row}{qw(legacy_type legacy_id)};
}

1;
