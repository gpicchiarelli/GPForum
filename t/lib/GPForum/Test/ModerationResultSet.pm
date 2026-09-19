package GPForum::Test::ModerationResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::ModerationRow;
use GPForum::Test::ModerationSearch;

our $VERSION = '0.001';

has created         => sub { return []; };
has created_objects => sub { return []; };
has find_misses     => 0;
has rows            => sub { return {}; };
has last_query      => sub { return {}; };
has last_attrs      => sub { return {}; };
has filter_search   => 0;
has skip_search     => 0;

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_unique_row($row);
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

    if ( $self->find_misses ) {
        $self->find_misses( $self->find_misses - 1 );
        return;
    }

    my $key = ref $query eq 'HASH' ? _find_key($query) : $query;

    return $self->rows->{$key};
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->last_query($query);
    $self->last_attrs( $attrs || {} );

    if ( $self->skip_search ) {
        $self->skip_search( $self->skip_search - 1 );
        return GPForum::Test::ModerationSearch->new( rows => [] );
    }

    my @candidate_rows =
        @{ $self->created_objects }
      ? @{ $self->created_objects }
      : values %{ $self->rows };
    my %seen;
    my @rows = grep { !$seen{ 0 + $_ }++ } @candidate_rows;
    if ( $self->filter_search || _should_filter($query) ) {
        @rows = grep { _matches_query( $_, $query ) } @rows;
    }

    return GPForum::Test::ModerationSearch->new( rows => \@rows );
}

sub _assert_unique_row {
    my ( $self, $row ) = @_;

    $self->_assert_open_report_unique($row);
    $self->_assert_command_unique($row);

    return;
}

sub _assert_open_report_unique {
    my ( $self, $row ) = @_;

    if ( !$row->{report_id} || !_open_status( $row->{status} ) ) {
        return;
    }

    for my $existing ( @{ $self->created } ) {
        if ( _same_open_report( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'idx_reports_reporter_target_open_unique');
        }
    }

    return;
}

sub _assert_command_unique {
    my ( $self, $row ) = @_;

    my $command_id = $row->{command_id};
    if ( !defined $command_id || !length $command_id ) {
        return;
    }

    for my $existing ( @{ $self->created } ) {
        if ( ( $existing->{command_id} || q{} ) eq $command_id ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'idx_moderation_actions_command_id');
        }
    }

    return;
}

sub _open_status {
    my ($status) = @_;

    return 0 if !defined $status;
    return 1 if $status eq 'open';
    return 1 if $status eq 'triaged';

    return 0;
}

sub _same_open_report {
    my ( $existing, $row ) = @_;

    if ( !_open_status( $existing->{status} ) ) {
        return 0;
    }
    if ( ( $existing->{reporter_user_id} || q{} ) ne $row->{reporter_user_id} )
    {
        return 0;
    }
    if ( ( $existing->{target_type} || q{} ) ne $row->{target_type} ) {
        return 0;
    }

    return ( $existing->{target_id} || q{} ) eq $row->{target_id} ? 1 : 0;
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
              command_id
              event_id
              outbox_id
              category_id
              space_id
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
              id
              user_id
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

sub _should_filter {
    my ($query) = @_;

    if ( !$query ) {
        return 0;
    }
    if ( exists $query->{command_id} ) {
        return 1;
    }
    if ( exists $query->{reporter_user_id} ) {
        return 1;
    }

    return 0;
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

sub _legacy_key {
    my ($row) = @_;

    return join q{:}, grep { defined } @{$row}{qw(legacy_type legacy_id)};
}

1;
