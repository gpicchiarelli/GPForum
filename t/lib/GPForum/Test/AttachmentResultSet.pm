package GPForum::Test::AttachmentResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::AttachmentRow;

our $VERSION = '0.001';

has created     => sub { return []; };
has find_misses => 0;
has last_attrs  => sub { return {}; };
has last_query  => sub { return {}; };
has rows        => sub { return {}; };
has skip_search => 0;

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_intent_unique($row);
    $self->_assert_link_id_unique($row);
    $self->_assert_link_unique($row);
    $self->_assert_variant_id_unique($row);
    $self->_assert_variant_unique($row);
    my $object = GPForum::Test::AttachmentRow->new( data => $row );
    push @{ $self->created }, $row;
    $self->_store_row( $row, $object );

    return $object;
}

sub find {
    my ( $self, $id ) = @_;

    if ( $self->find_misses ) {
        $self->find_misses( $self->find_misses - 1 );
        return;
    }

    return $self->rows->{$id};
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->last_query( $query || {} );
    $self->last_attrs( $attrs || {} );

    my $skipped = $self->_skipped_search;
    if ($skipped) {
        return $skipped;
    }

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

sub _skipped_search {
    my ($self) = @_;

    if ( !$self->skip_search ) {
        return;
    }

    $self->skip_search( $self->skip_search - 1 );

    return GPForum::Test::AttachmentSearch->new( rows => [] );
}

sub _assert_intent_unique {
    my ( $self, $row ) = @_;

    if ( !_intent_row($row) ) {
        return;
    }

    for my $existing ( @{ $self->created } ) {
        if ( _same_intent( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                _intent_conflict( $existing, $row ) );
        }
    }

    return;
}

sub _intent_row {
    my ($row) = @_;

    if ( !_has_text( $row->{attachment_id} ) ) {
        return 0;
    }
    if ( _has_text( $row->{attachment_link_id} ) ) {
        return 0;
    }
    if ( _has_text( $row->{attachment_variant_id} ) ) {
        return 0;
    }

    return _has_text( $row->{object_key} );
}

sub _same_intent {
    my ( $existing, $row ) = @_;

    if ( !_intent_row($existing) ) {
        return 0;
    }
    if ( _same_text( $existing->{attachment_id}, $row->{attachment_id} ) ) {
        return 1;
    }

    return _same_text( $existing->{object_key}, $row->{object_key} );
}

sub _intent_conflict {
    my ( $existing, $row ) = @_;

    if ( _same_text( $existing->{attachment_id}, $row->{attachment_id} ) ) {
        return 'attachments_pkey';
    }

    return 'attachments_object_key_key';
}

sub _assert_link_id_unique {
    my ( $self, $row ) = @_;

    if ( !_link_row($row) ) {
        return;
    }
    if ( _link_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('attachment_links_pkey');
    }

    return;
}

sub _assert_link_unique {
    my ( $self, $row ) = @_;

    if ( !_link_row($row) ) {
        return;
    }

    for my $existing ( @{ $self->created } ) {
        if ( _same_link_target( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'attachment_links_target_key');
        }
    }

    return;
}

sub _link_id_taken {
    my ( $self, $row ) = @_;

    if ( !_has_text( $row->{attachment_link_id} ) ) {
        return 0;
    }

    for my $existing ( @{ $self->created } ) {
        if (
            _same_text(
                $existing->{attachment_link_id},
                $row->{attachment_link_id}
            )
          )
        {
            return 1;
        }
    }

    return 0;
}

sub _link_row {
    my ($row) = @_;

    if ( !_has_text( $row->{attachment_link_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{attachment_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{target_type} ) ) {
        return 0;
    }

    return _has_text( $row->{target_id} );
}

sub _same_link_target {
    my ( $existing, $row ) = @_;

    if ( !_link_row($existing) ) {
        return 0;
    }

    return _same_link_scope( $existing, $row );
}

sub _same_link_scope {
    my ( $existing, $row ) = @_;

    if ( !_same_text( $existing->{attachment_id}, $row->{attachment_id} ) ) {
        return 0;
    }
    if ( !_same_text( $existing->{target_type}, $row->{target_type} ) ) {
        return 0;
    }

    return _same_text( $existing->{target_id}, $row->{target_id} );
}

sub _assert_variant_id_unique {
    my ( $self, $row ) = @_;

    if ( !_variant_row($row) ) {
        return;
    }
    if ( _variant_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'attachment_variants_pkey');
    }

    return;
}

sub _assert_variant_unique {
    my ( $self, $row ) = @_;

    if ( !_variant_row($row) ) {
        return;
    }

    for my $existing ( @{ $self->created } ) {
        if ( _same_variant_object( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'attachment_variants_object_key_key');
        }
        if ( _same_variant_key( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'attachment_variants_variant_key');
        }
    }

    return;
}

sub _variant_id_taken {
    my ( $self, $row ) = @_;

    if ( !_has_text( $row->{attachment_variant_id} ) ) {
        return 0;
    }

    for my $existing ( @{ $self->created } ) {
        if (
            _same_text(
                $existing->{attachment_variant_id},
                $row->{attachment_variant_id}
            )
          )
        {
            return 1;
        }
    }

    return 0;
}

sub _variant_row {
    my ($row) = @_;

    if ( !_has_text( $row->{attachment_variant_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{attachment_id} ) ) {
        return 0;
    }

    return _has_text( $row->{variant_type} );
}

sub _same_variant_object {
    my ( $existing, $row ) = @_;

    if ( !_variant_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{object_key}, $row->{object_key} );
}

sub _same_variant_key {
    my ( $existing, $row ) = @_;

    if ( !_variant_row($existing) ) {
        return 0;
    }
    if ( !_same_text( $existing->{attachment_id}, $row->{attachment_id} ) ) {
        return 0;
    }

    return _same_text( $existing->{variant_type}, $row->{variant_type} );
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
