# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::NotificationResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::Query;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::NotificationRow;
use GPForum::Test::NotificationSearch;

our $VERSION = '0.001';

has created     => sub { return []; };
has fail_create => 0;
has find_misses => 0;
has rows        => sub { return {}; };
has last_query  => sub { return {}; };
has last_attrs  => sub { return {}; };
has schema      => undef;

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_usable;
    die 'notification create failed' if $self->fail_create;
    $self->_assert_unique_constraints($row);

    my $object = GPForum::Test::NotificationRow->new( data => $row );
    push @{ $self->created }, $row;
    $self->_store_row( $row, $object );

    return $object;
}

sub update_or_create {
    my ( $self, $row ) = @_;

    my $existing = $self->find($row);
    if ($existing) {
        $existing->update($row);
        return $existing;
    }

    return $self->create($row);
}

sub find {
    my ( $self, $query ) = @_;

    $self->_assert_usable;
    if ( $self->_consume_find_miss ) {
        return;
    }

    return $self->_lookup_row($query);
}

sub _consume_find_miss {
    my ($self) = @_;

    if ( !$self->find_misses ) {
        return 0;
    }

    $self->find_misses( $self->find_misses - 1 );

    return 1;
}

sub _lookup_row {
    my ( $self, $query ) = @_;

    my $unique = ref $query eq 'HASH' ? _subscription_unique($query) : undef;
    if ( $unique && $self->rows->{$unique} ) {
        return $self->rows->{$unique};
    }

    my $key = ref $query eq 'HASH' ? _composite_key($query) : $query;

    return $self->rows->{$key};
}

# DBIx::Class's context-proof form of search. lib/ calls it wherever it means a
# resultset, because search itself returns every row in list context.
sub search_rs {
    my ( $self, @arguments ) = @_;

    return $self->search(@arguments);
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->_assert_usable;
    $self->last_query($query);
    $self->last_attrs( $attrs || {} );

    my %seen;
    my @rows = grep { !$seen{ 0 + $_ }++ } values %{ $self->rows };
    @rows = grep { _matches_query( $_, $query ) } @rows;
    @rows =
      GPForum::Test::Query::ordered_rows( \@rows, $attrs, \&_read_column );
    @rows = GPForum::Test::Query::windowed_rows( \@rows, $attrs );

    return GPForum::Test::NotificationSearch->new( rows => \@rows, );
}

# A unique violation is what puts a real transaction into the aborted state.
# Marking it here is what makes the double able to fail a recovery path that
# would be unreachable against PostgreSQL.
sub _assert_unique_constraints {
    my ( $self, $row ) = @_;

    my $ok = eval {
        $self->_run_unique_constraints($row);
        1;
    };
    if ( !$ok ) {
        my $failure = $@;
        $self->_mark_aborted;
        die $failure;    ## no critic (ErrorHandling::RequireCarping)
    }

    return;
}

sub _run_unique_constraints {
    my ( $self, $row ) = @_;

    $self->_assert_subscription_id_unique($row);
    $self->_assert_subscription_unique($row);
    $self->_assert_notification_unique($row);
    $self->_assert_inbox_unique($row);
    $self->_assert_preference_unique($row);
    $self->_assert_read_unique($row);

    return;
}

# A resultset double is also used with a schema that has not adopted
# GPForum::Test::TransactionalSchema, and standalone with no schema at all.
sub _assert_usable {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( $schema && $schema->can('assert_transaction_usable') ) {
        $schema->assert_transaction_usable;
    }

    return;
}

sub _mark_aborted {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( $schema && $schema->can('mark_transaction_aborted') ) {
        $schema->mark_transaction_aborted;
    }

    return;
}

sub _assert_subscription_id_unique {
    my ( $self, $row ) = @_;

    if ( !_has_text( $row->{subscription_id} ) ) {
        return;
    }
    if ( $self->rows->{ $row->{subscription_id} } ) {
        GPForum::Infrastructure::UniqueConflict->throw('subscriptions_pkey');
    }

    return;
}

sub _assert_subscription_unique {
    my ( $self, $row ) = @_;

    my $key = _subscription_unique($row);
    if ( $key && $self->rows->{$key} ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'subscriptions_unique_target');
    }

    return;
}

sub _assert_notification_unique {
    my ( $self, $row ) = @_;

    if ( !_notification_pk_row($row) ) {
        return;
    }

    for my $existing ( @{ $self->created } ) {
        if ( _same_notification_pk( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'notifications_pkey');
        }
    }

    return;
}

sub _notification_pk_row {
    my ($row) = @_;

    if ( !_has_text( $row->{source_type} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{notification_id} ) ) {
        return 0;
    }

    return _has_text( $row->{created_at} );
}

sub _same_notification_pk {
    my ( $existing, $row ) = @_;

    if ( !_notification_pk_row($existing) ) {
        return 0;
    }
    if ( !_same_text( $existing->{notification_id}, $row->{notification_id} ) )
    {
        return 0;
    }

    return _same_text( $existing->{created_at}, $row->{created_at} );
}

sub _assert_inbox_unique {
    my ( $self, $row ) = @_;

    if ( !_inbox_row($row) ) {
        return;
    }

    for my $existing ( @{ $self->created } ) {
        if ( _same_inbox_key( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'notification_inbox_pkey');
        }
    }

    return;
}

sub _inbox_row {
    my ($row) = @_;

    if ( !exists $row->{rank_score} ) {
        return 0;
    }
    if ( _has_text( $row->{source_type} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{notification_id} ) ) {
        return 0;
    }

    return _has_text( $row->{recipient_user_id} );
}

sub _same_inbox_key {
    my ( $existing, $row ) = @_;

    if ( !_inbox_row($existing) ) {
        return 0;
    }
    if ( !_same_text( $existing->{notification_id}, $row->{notification_id} ) )
    {
        return 0;
    }

    return _same_text( $existing->{recipient_user_id},
        $row->{recipient_user_id} );
}

sub _assert_preference_unique {
    my ( $self, $row ) = @_;

    if ( !_preference_row($row) ) {
        return;
    }

    for my $existing ( @{ $self->created } ) {
        if ( _same_preference_key( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'notification_preferences_pkey');
        }
    }

    return;
}

sub _preference_row {
    my ($row) = @_;

    if ( _has_text( $row->{target_type} ) ) {
        return 0;
    }
    if ( _has_text( $row->{notification_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{user_id} ) ) {
        return 0;
    }

    return _has_text( $row->{channel} );
}

sub _same_preference_key {
    my ( $existing, $row ) = @_;

    if ( !_preference_row($existing) ) {
        return 0;
    }
    if ( !_same_text( $existing->{user_id}, $row->{user_id} ) ) {
        return 0;
    }

    return _same_text( $existing->{channel}, $row->{channel} );
}

sub _assert_read_unique {
    my ( $self, $row ) = @_;

    if ( !_read_row($row) ) {
        return;
    }

    for my $existing ( @{ $self->created } ) {
        if ( _same_read_key( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'notification_reads_pkey');
        }
    }

    return;
}

sub _read_row {
    my ($row) = @_;

    if ( exists $row->{rank_score} ) {
        return 0;
    }
    if ( _has_text( $row->{source_type} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{notification_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{recipient_user_id} ) ) {
        return 0;
    }

    return _has_text( $row->{read_at} );
}

sub _same_read_key {
    my ( $existing, $row ) = @_;

    if ( !_read_row($existing) ) {
        return 0;
    }
    if ( !_same_text( $existing->{notification_id}, $row->{notification_id} ) )
    {
        return 0;
    }

    return _same_text( $existing->{recipient_user_id},
        $row->{recipient_user_id} );
}

sub _has_text {
    my ($value) = @_;

    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

sub _same_text {
    my ( $stored, $candidate ) = @_;

    $stored    = defined $stored    ? $stored    : q{};
    $candidate = defined $candidate ? $candidate : q{};

    return $stored eq $candidate ? 1 : 0;
}

sub _subscription_unique {
    my ($row) = @_;

    if ( !$row->{user_id} || !$row->{target_type} || !$row->{target_id} ) {
        return;
    }

    return join q{:}, $row->{user_id}, $row->{target_type}, $row->{target_id};
}

sub _store_row {
    my ( $self, $row, $object ) = @_;

    my $key =
         $row->{subscription_id}
      || $row->{notification_id}
      || $row->{user_id}
      || $row->{idempotency_key}
      || _composite_key($row);
    $self->rows->{$key} = $object;
    $self->rows->{ _composite_key($row) } = $object;
    $self->_index_subscription( $row, $object );

    return;
}

sub _index_subscription {
    my ( $self, $row, $object ) = @_;

    my $unique = _subscription_unique($row);
    if ($unique) {
        $self->rows->{$unique} = $object;
    }

    return;
}

sub _composite_key {
    my ($row) = @_;

    return join q{:},
      grep { defined }
      @{$row}{qw(user_id channel recipient_user_id notification_id)};
}

sub _matches_query {
    my ( $row, $query ) = @_;

    return 1 if !$query;

    for my $field ( keys %{$query} ) {
        next     if $field eq '-or' || $field eq '-and';
        return 0 if !_matches_field( $row, $field, $query->{$field} );
    }

    return 1;
}

sub _matches_field {
    my ( $row, $field, $expected ) = @_;

    my $actual = $row->get_column( _base_column($field) );

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

sub _base_column {
    my ($field) = @_;

    ( my $column = $field ) =~ s/\A me [.]//msx;

    return $column;
}

sub _read_column {
    my ( $row, $column ) = @_;

    return $row->get_column($column);
}

1;
