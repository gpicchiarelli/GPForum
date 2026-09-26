# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::CategoryStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Admin::Event;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $DEFAULT_SPACE_SLUG       => 'general';
const my $DEFAULT_SPACE_TITLE      => 'General';
const my $ROW_LIMIT_ONE            => 1;
const my $SCHEMA_VERSION           => 1;
const my $CATEGORY_ID_CONSTRAINT   => 'categories_pkey';
const my $CATEGORY_SLUG_CONSTRAINT => 'categories_space_slug_key';
const my $SPACE_ID_CONSTRAINT      => 'spaces_pkey';
const my $SPACE_SLUG_CONSTRAINT    => 'spaces_slug_key';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;
has events => sub { return GPForum::Service::Admin::Event->new; };

sub create_category ( $self, $input ) {
    return $self->_txn( sub { return $self->_create_once($input); } );
}

sub update_category ( $self, $input ) {
    return $self->_txn( sub { return $self->_update_once($input); } );
}

sub list_categories ( $self, $options ) {
    $options ||= {};
    my $search = $self->schema->resultset('Category')->search_rs(
        { deleted_at => undef },
        {
            order_by => [
                { -asc => 'position' },
                { -asc => 'title' },
                { -asc => 'category_id' },
            ],
            rows => $options->{limit},
        }
    );

    return [ _list_rows($search) ];
}

sub _txn ( $self, $code ) {
    return $self->schema->txn_do($code);
}

sub _create_once ( $self, $input ) {
    my $space = $self->_ensure_space($input);
    if ( !$space ) {
        my $undefined;
        return $undefined;
    }

    return $self->_insert_or_reuse(
        {
            %{$input},
            slug     => $self->_slug($input),
            space_id => $space->{space_id},
        }
    );
}

sub _insert_or_reuse ( $self, $input ) {
    my $existing = $self->_existing_category($input);
    if ($existing) {
        return $self->_finish_leftover_category( $existing, $input );
    }

    return $self->_insert_or_reuse_category($input);
}

sub _insert_or_reuse_category ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_category_row($input); },
      );
    if ($created) {
        return $created;
    }

    return $self->_category_after_conflict( $input, $error );
}

sub _category_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_category_after_unique( $input, $error );
}

sub _category_after_unique ( $self, $input, $error ) {
    if ( _category_id_conflict($error) ) {
        return $self->_category_after_id_conflict($input);
    }
    if ( _category_slug_conflict($error) ) {
        return $self->_reuse_category_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _category_after_id_conflict ( $self, $input ) {
    my $existing = $self->_existing_category($input);
    if ($existing) {
        return $self->_finish_leftover_category( $existing, $input );
    }

    return $self->_retry_category_id($input);
}

sub _retry_category_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_category_row($input); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reuse_category_row ( $self, $input, $error ) {
    my $existing = $self->_existing_category($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_finish_leftover_category( $existing, $input );
}

sub _category_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $CATEGORY_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _category_slug_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $CATEGORY_SLUG_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_category_row ( $self, $input ) {
    my $category = $self->_new_category($input);
    $self->schema->resultset('Category')->create($category);
    $self->_record_write(
        {
            action        => 'category.created',
            actor_user_id => $input->{actor_user_id},
            category      => $category,
        }
    );

    return $category;
}

sub _update_once ( $self, $input ) {
    my $row = $self->_visible_category( $input->{category_id} );
    if ( !$row ) {
        my $undefined;
        return $undefined;
    }

    my $updates = $self->_update_fields( $input, $row );
    if ( _unchanged_category( $row, $updates ) ) {
        return _skipped_category($row);
    }

    $row->update($updates);
    my $category = { %{ _row_hash( $row, _category_columns() ) }, %{$updates} };
    $self->_record_write(
        {
            action        => 'category.updated',
            actor_user_id => $input->{actor_user_id},
            category      => $category,
        }
    );

    return $category;
}

sub _unchanged_category ( $row, $updates ) {
    if ( !_same_copy( $row, $updates ) ) {
        return 0;
    }

    return _same_position( _column( $row, 'position' ), $updates->{position} );
}

sub _same_copy ( $row, $updates ) {
    for my $name (qw(description slug title visibility)) {
        if ( !_same_text( _column( $row, $name ), $updates->{$name} ) ) {
            return 0;
        }
    }

    return 1;
}

sub _same_text ( $held, $incoming ) {
    $held     = defined $held     ? $held     : q{};
    $incoming = defined $incoming ? $incoming : q{};

    return $held eq $incoming ? 1 : 0;
}

sub _same_position ( $held, $incoming ) {
    $held     = defined $held     ? $held     : 0;
    $incoming = defined $incoming ? $incoming : 0;

    return $held == $incoming ? 1 : 0;
}

sub _skipped_category ($row) {
    return { %{ _row_hash( $row, _category_columns() ) }, skipped => 1, };
}

sub _ensure_space ( $self, $input ) {
    my $space_id = _trim( $input->{space_id} );
    if ( length $space_id ) {
        return $self->_space_by_id($space_id);
    }

    my $first = $self->_first_space;
    if ($first) {
        return $first;
    }

    return $self->_default_space;
}

sub _space_by_id ( $self, $space_id ) {
    return _row_hash( $self->schema->resultset('Space')->find($space_id),
        _space_columns() );
}

sub _first_space ($self) {
    my $search = $self->schema->resultset('Space')->search_rs(
        { deleted_at => undef },
        {
            order_by => [ { -asc => 'position' }, { -asc => 'slug' } ],
            rows     => $ROW_LIMIT_ONE,
        }
    );

    return _row_hash( _single($search), _space_columns() );
}

sub _default_space ($self) {
    my $existing = $self->_space_by_slug;
    if ($existing) {
        return $existing;
    }

    return $self->_insert_or_reuse_space;
}

sub _insert_or_reuse_space ($self) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_default_space; },
      );
    if ($created) {
        return $created;
    }

    return $self->_space_after_conflict($error);
}

sub _space_after_conflict ( $self, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_space_after_unique($error);
}

sub _space_after_unique ( $self, $error ) {
    if ( _space_id_conflict($error) ) {
        return $self->_space_after_id_conflict;
    }
    if ( _space_slug_conflict($error) ) {
        return $self->_reuse_space_row($error);
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _space_after_id_conflict ($self) {
    my $existing = $self->_space_by_slug;
    if ($existing) {
        return $existing;
    }

    return $self->_retry_space_id;
}

sub _retry_space_id ($self) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_default_space; },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reuse_space_row ( $self, $error ) {
    my $existing = $self->_space_by_slug;
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $existing;
}

sub _space_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $SPACE_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _space_slug_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $SPACE_SLUG_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _insert_default_space ($self) {
    my $now   = $self->clock->now_iso8601;
    my $space = {
        created_at         => $now,
        deleted_at         => undef,
        description        => q{},
        permission_version => $SCHEMA_VERSION,
        position           => 0,
        slug               => $DEFAULT_SPACE_SLUG,
        space_id           => $self->id_service->uuid,
        title              => $DEFAULT_SPACE_TITLE,
        updated_at         => $now,
        version            => $SCHEMA_VERSION,
        visibility         => 'public',
    };
    $self->schema->resultset('Space')->create($space);

    return $space;
}

sub _space_by_slug ($self) {
    my $search =
      $self->schema->resultset('Space')
      ->search_rs( { slug => $DEFAULT_SPACE_SLUG },
        { rows => $ROW_LIMIT_ONE } );

    return _row_hash( _single($search), _space_columns() );
}

sub _existing_category ( $self, $input ) {
    my $search = $self->schema->resultset('Category')->search_rs(
        {
            deleted_at => undef,
            slug       => $input->{slug},
            space_id   => $input->{space_id},
        },
        { rows => $ROW_LIMIT_ONE }
    );

    return _row_hash( _single($search), _category_columns() );
}

sub _visible_category ( $self, $category_id ) {
    my $undefined;

    my $row = $self->schema->resultset('Category')->find($category_id);
    if ( !$row ) {
        return $undefined;
    }
    if ( defined _column( $row, 'deleted_at' ) ) {
        return $undefined;
    }

    return $row;
}

sub _new_category ( $self, $input ) {
    my $now = $self->clock->now_iso8601;

    return {
        category_id        => $self->id_service->uuid,
        created_at         => $now,
        deleted_at         => undef,
        description        => _trim( $input->{description} ),
        permission_version => $SCHEMA_VERSION,
        position           => _position( $input->{position} ),
        slug               => $input->{slug},
        space_id           => $input->{space_id},
        title              => _trim( $input->{title} ),
        updated_at         => $now,
        version            => $SCHEMA_VERSION,
        visibility         => _visibility( $input->{visibility} ),
    };
}

sub _update_fields ( $self, $input, $row ) {
    return {
        description =>
          _kept_text( $input->{description}, _column( $row, 'description' ) ),
        position =>
          _kept_position( $input->{position}, _column( $row, 'position' ) ),
        slug       => _kept_text( $input->{slug},  _column( $row, 'slug' ) ),
        title      => _kept_text( $input->{title}, _column( $row, 'title' ) ),
        updated_at => $self->clock->now_iso8601,
        version    => _column( $row, 'version' ) + 1,
        visibility => _kept_visibility(
            $input->{visibility}, _column( $row, 'visibility' )
        ),
    };
}

sub _finish_leftover_category ( $self, $existing, $input ) {
    $self->_ensure_category_write( $existing, $input );

    return { %{$existing}, idempotent => 1 };
}

sub _ensure_category_write ( $self, $existing, $input ) {
    if ( $self->_category_event_exists($existing) ) {
        my $undefined;
        return $undefined;
    }

    return $self->_record_write(
        {
            action        => 'category.created',
            actor_user_id => $input->{actor_user_id},
            category      => $existing,
        }
    );
}

sub _category_event_exists ( $self, $existing ) {
    return $self->recorder->event_recorded( join q{:}, 'category.created',
        $existing->{category_id} );
}

sub _record_write ( $self, $input ) {
    my $correlation_id = $self->id_service->uuid;
    my $payload        = {
        %{$input},
        correlation_id => $correlation_id,
        created_at     => $input->{category}{updated_at}
          || $input->{category}{created_at},
    };
    $self->recorder->record_event(
        %{ $self->events->category_event($payload) } );
    $self->recorder->record_audit(
        %{ $self->events->category_audit($payload) } );

    return;
}

sub _slug ( $, $input ) {
    my $provided = _trim( $input->{slug} );
    if ( length $provided ) {
        return $provided;
    }

    return _slug_from_title( $input->{title} );
}

sub _slug_from_title ($title) {
    my $slug = lc _trim($title);
    $slug =~ s/[^[:alnum:]]+/-/gmsx;
    $slug =~ s/\A [-]+//msx;
    $slug =~ s/[-]+ \z//msx;
    if ( length $slug ) {
        return $slug;
    }

    return $DEFAULT_SPACE_SLUG;
}

sub _visibility ($value) {
    my $trimmed = _trim($value);
    if ( length $trimmed ) {
        return $trimmed;
    }

    return 'public';
}

sub _position ($value) {
    my $trimmed = _trim($value);
    if ( $trimmed =~ /\A -? [[:digit:]]+ \z/msx ) {
        return int $trimmed;
    }

    return 0;
}

sub _kept_text ( $value, $current ) {
    my $trimmed = _trim($value);
    if ( length $trimmed ) {
        return $trimmed;
    }

    return $current;
}

sub _kept_position ( $value, $current ) {
    if ( !defined $value || !length _trim($value) ) {
        return $current;
    }

    return _position($value);
}

sub _kept_visibility ( $value, $current ) {
    my $trimmed = _trim($value);
    if ( !length $trimmed ) {
        return $current;
    }

    return _visibility($trimmed);
}

sub _single ($search) {
    if ( $search->can('single') ) {
        return $search->single;
    }
    if ( $search->can('all') ) {
        my @rows = $search->all;
        return $rows[0];
    }
    if ( $search->can('rows') ) {
        return $search->rows->[0];
    }

    my $undefined;
    return $undefined;
}

sub _list_rows ($search) {
    if ( $search->can('all') ) {
        return $search->all;
    }
    if ( $search->can('rows') ) {
        return @{ $search->rows };
    }

    return;
}

sub _row_hash ( $row, @columns ) {
    if ( !$row ) {
        my $undefined;
        return $undefined;
    }

    my %hash = map { $_ => _column( $row, $_ ) } @columns;

    return \%hash;
}

sub _column ( $row, $column ) {
    return GPForum::Infrastructure::Row->column( $row, $column );
}

sub _trim ($value) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _category_columns {
    return
      qw(category_id space_id slug title description visibility position version created_at updated_at deleted_at);
}

sub _space_columns {
    return qw(space_id slug title description visibility position created_at);
}

1;

__END__

=head1 NAME

GPForum::Service::Admin::CategoryStore - Admin category persistence.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $stored = $store->create_category(
        {
            actor_user_id => $user_id,
            title         => $title,
        }
    );

=head1 DESCRIPTION

Owns category create and update transactions for the admin catalog. A missing
space id on a fresh install creates a default public C<general> space so the
first administrator can add the first category without PerformanceSeed. Event,
audit, and outbox rows are written through L<GPForum::Infrastructure::EventRecorder>
using L<GPForum::Service::Admin::Event> hashes.

=head1 SUBROUTINES/METHODS

=head2 create_category

Creates a category, or returns the existing space/slug row idempotently.
A unique race on the default C<general> space slug reuses the existing
space instead of inserting a second row.

=head2 update_category

Updates a visible category. Returns undef when the category is missing.
A second write of the same title, slug, description, visibility, and
position returns C<skipped> and does not bump version, restamp
C<updated_at>, or emit another event, audit, or outbox row.

=head2 list_categories

Returns visible categories ordered by position and title.

=head1 DIAGNOSTICS

Returns undef when a requested space or category cannot be resolved. Unexpected
database errors propagate to L<GPForum::Service::Admin::Workflow>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the schema, clock, and id service supplied by the composition root.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>, L<GPForum::Infrastructure::EventRecorder>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Service::Admin::Event>,
and L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Public category-list cache tags are invalidated by
L<GPForum::Worker::Handler::CacheInvalidation> after the outbox dispatches
C<category.created> and C<category.updated>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
