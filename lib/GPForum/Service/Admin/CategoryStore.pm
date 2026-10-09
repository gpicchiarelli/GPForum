# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::CategoryStore;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Id;
use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Admin::Event;
use GPForum::Service::Clock;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $DEFAULT_SPACE_SLUG       => 'general';
const my $DEFAULT_SPACE_TITLE      => 'General';
const my $ROW_LIMIT_ONE            => 1;
const my $SCHEMA_VERSION           => 1;
const my $CATEGORY_ID_CONSTRAINT   => 'categories_pkey';
const my $CATEGORY_SLUG_CONSTRAINT => 'categories_space_slug_key';
const my $SPACE_ID_CONSTRAINT      => 'spaces_pkey';
const my $SPACE_SLUG_CONSTRAINT    => 'spaces_slug_key';
const my $SLUG_TAKEN               => 'slug is taken';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
has recorder   => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
__PACKAGE__->requires(qw(schema));
has events => sub { return GPForum::Service::Admin::Event->new; };

sub create_category ( $self, $input ) {
    return $self->schema->txn_do( sub { return $self->_create_once($input); } );
}

sub update_category ( $self, $input ) {
    return $self->schema->txn_do( sub { return $self->_update_once($input); } );
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
    if ( $search->can('all') ) {
        return [ $search->all ];
    }
    if ( $search->can('rows') ) {
        return [ @{ $search->rows } ];
    }

    return [];
}

# A live category already holding the slug in the space is this create,
# committed by an earlier attempt, and is reused. A concurrent create, or a
# minted id already stored, is answered by the live category then found; a
# minted id with none is minted once more.
#
# The slug key holds every row, soft-deleted ones too, while the store looks
# only for a live category. A slug conflict with no live row behind it is a
# soft-deleted category's slug: the slug is taken, as a validation error, not
# a database failure. The INSERT ran in a savepoint, so nothing was written.
sub _create_once ( $self, $input ) {
    my $space = $self->_ensure_space($input);
    if ( !$space ) {
        return undef;
    }

    my $category = {
        %{$input},
        slug     => _slug($input),
        space_id => $space->{space_id},
    };
    my $existing = $self->_existing_category($category);
    if ($existing) {
        return $self->_finish_leftover_category( $existing, $category );
    }

    my $create = sub { return $self->_create_category_row($category); };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $create );
    if ($created) {
        return $created;
    }

    my $conflict = GPForum::X::Conflict->caught($error);
    my $id_taken = $conflict && $conflict->on($CATEGORY_ID_CONSTRAINT);
    if ( $id_taken
        || ( $conflict && $conflict->on($CATEGORY_SLUG_CONSTRAINT) ) )
    {
        $existing = $self->_existing_category($category);
        if ($existing) {
            return $self->_finish_leftover_category( $existing, $category );
        }
        return $id_taken ? $self->_once_more($create) : _slug_taken();
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _slug_taken {
    return { errors => { slug => $SLUG_TAKEN } };
}

# The second attempt after a minted id collided: any failure is final.
sub _once_more ( $self, $create ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $create );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _create_category_row ( $self, $input ) {
    my $now      = $self->clock->now_iso8601;
    my $category = {
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
        visibility         => _kept_text( $input->{visibility}, q{public} ),
    };
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

# A field left out keeps its value; an update that changes nothing is
# skipped. A slug moved onto another category's, live or soft-deleted, meets
# the space and slug key: the slug is taken. The UPDATE ran in a savepoint,
# so the transaction goes on.
sub _update_once ( $self, $input ) {
    my $row = $self->_visible_category( $input->{category_id} );
    if ( !$row ) {
        return undef;
    }

    my $position = _trim( $input->{position} );
    $position =
      length $position ? _position($position) : _column( $row, q{position} );
    my $updates = {
        description =>
          _kept_text( $input->{description}, _column( $row, 'description' ) ),
        position   => $position,
        slug       => _kept_text( $input->{slug},  _column( $row, 'slug' ) ),
        title      => _kept_text( $input->{title}, _column( $row, 'title' ) ),
        updated_at => $self->clock->now_iso8601,
        version    => _column( $row, 'version' ) + 1,
        visibility =>
          _kept_text( $input->{visibility}, _column( $row, 'visibility' ) ),
    };
    if ( _unchanged_category( $row, $updates ) ) {
        return { %{ _row_hash( $row, _category_columns() ) }, skipped => 1, };
    }

    my ( undef, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $row->update($updates); } );
    if ($error) {

        # The server's own sentence decides, not the constraint's name
        # anywhere in the text: an over-long slug fails the index (index row
        # size exceeds the maximum for categories_space_slug_key), which is
        # no slug taken.
        my $conflict = GPForum::X::Conflict->caught($error);
        if ( $conflict && $conflict->on($CATEGORY_SLUG_CONSTRAINT) ) {
            return _slug_taken();
        }
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

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

# Text compares with undef as empty, the position with undef as 0.
sub _unchanged_category ( $row, $updates ) {
    for my $name (qw(description slug title visibility)) {
        if ( ( _column( $row, $name ) // q{} ) ne ( $updates->{$name} // q{} ) )
        {
            return 0;
        }
    }

    return ( _column( $row, 'position' ) // 0 ) == ( $updates->{position} // 0 )
      ? 1
      : 0;
}

# The space the request names; without one, the first live space; without
# any, the default space.
sub _ensure_space ( $self, $input ) {
    my $space_id = _trim( $input->{space_id} );
    if ( length $space_id ) {

        # An id from the request that is not a uuid names no row. PostgreSQL
        # refuses it as a uuid parameter, which would answer 503 for what is
        # a 404.
        if ( !GPForum::Infrastructure::Id->is_uuid($space_id) ) {
            return undef;
        }
        return _row_hash( $self->schema->resultset('Space')->find($space_id),
            _space_columns() );
    }

    my $first = _row_hash(
        _single(
            $self->schema->resultset('Space')->search_rs(
                { deleted_at => undef },
                {
                    order_by => [ { -asc => 'position' }, { -asc => 'slug' } ],
                    rows     => $ROW_LIMIT_ONE,
                }
            )
        ),
        _space_columns()
    );
    if ($first) {
        return $first;
    }

    return $self->_default_space;
}

# The default space is created once. A concurrent creation, or a minted id
# already stored, is answered by the space then found by its slug; a minted
# id with none is minted once more.
sub _default_space ($self) {
    my $existing = $self->_space_by_slug;
    if ($existing) {
        return $existing;
    }

    my $create = sub { return $self->_insert_default_space; };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $create );
    if ($created) {
        return $created;
    }

    my $conflict = GPForum::X::Conflict->caught($error);
    my $id_taken = $conflict && $conflict->on($SPACE_ID_CONSTRAINT);
    if ( $id_taken || ( $conflict && $conflict->on($SPACE_SLUG_CONSTRAINT) ) ) {
        $existing = $self->_space_by_slug;
        if ($existing) {
            return $existing;
        }
        if ($id_taken) {
            return $self->_once_more($create);
        }
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
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
    if ( !GPForum::Infrastructure::Id->is_uuid($category_id) ) {
        return undef;
    }

    my $row = $self->schema->resultset('Category')->find($category_id);
    if ( !$row ) {
        return undef;
    }
    if ( defined _column( $row, 'deleted_at' ) ) {
        return undef;
    }

    return $row;
}

# An earlier attempt may have committed the category without its event.
sub _finish_leftover_category ( $self, $existing, $input ) {
    my $event_key = join q{:}, 'category.created', $existing->{category_id};
    if ( !$self->recorder->event_recorded($event_key) ) {
        $self->_record_write(
            {
                action        => 'category.created',
                actor_user_id => $input->{actor_user_id},
                category      => $existing,
            }
        );
    }

    return { %{$existing}, idempotent => 1 };
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

# The slug given, or one made from the title.
sub _slug ($input) {
    my $provided = _trim( $input->{slug} );
    if ( length $provided ) {
        return $provided;
    }

    my $slug = lc _trim( $input->{title} );
    $slug =~ s/[^[:alnum:]]+/-/gmsx;
    $slug =~ s/\A [-]+//msx;
    $slug =~ s/[-]+ \z//msx;
    if ( length $slug ) {
        return $slug;
    }

    return $DEFAULT_SPACE_SLUG;
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

    return undef;
}

sub _row_hash ( $row, @columns ) {
    if ( !$row ) {
        return undef;
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
space instead of inserting a second row. Returns undef when a C<space_id>
is given that is not a uuid or names no space, and
C<< { errors => { slug => 'slug is taken' } } >> when the slug belongs to a
soft-deleted category of the space (the space and slug key is not partial).

=head2 update_category

Updates a visible category. Returns undef when the category id is not a
uuid or names no visible category, and
C<< { errors => { slug => 'slug is taken' } } >> when the new slug belongs to
another category of the space, live or soft-deleted.
A second write of the same title, slug, description, visibility, and
position returns C<skipped> and does not bump version, restamp
C<updated_at>, or emit another event, audit, or outbox row.

=head2 list_categories

Returns visible categories ordered by position and title.

=head1 DIAGNOSTICS

Returns undef when a requested space or category cannot be resolved, an id
that is not a uuid included: it is checked before any statement is sent.
Returns an C<errors> hash when the slug is taken. Unexpected database errors
propagate to L<GPForum::Service::Admin::Workflow>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the schema, clock, and id service supplied by the composition root.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<GPForum::Base>,
L<GPForum::Infrastructure::EventRecorder>, L<GPForum::Infrastructure::Id>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::X::Conflict>,
L<GPForum::Service::Admin::Event>, and L<GPForum::Service::Clock>.

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
