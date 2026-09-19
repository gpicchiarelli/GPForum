package GPForum::Service::Admin::CategoryStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Admin::Event;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $DEFAULT_SPACE_SLUG  => 'general';
const my $DEFAULT_SPACE_TITLE => 'General';
const my $ROW_LIMIT_ONE       => 1;
const my $SCHEMA_VERSION      => 1;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
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

sub create_category {
    my ( $self, $input ) = @_;

    return $self->_txn( sub { return $self->_create_once($input); } );
}

sub update_category {
    my ( $self, $input ) = @_;

    return $self->_txn( sub { return $self->_update_once($input); } );
}

sub list_categories {
    my ( $self, $options ) = @_;

    $options ||= {};
    my $search = $self->schema->resultset('Category')->search(
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

sub _txn {
    my ( $self, $code ) = @_;

    return $self->schema->txn_do($code);
}

sub _create_once {
    my ( $self, $input ) = @_;

    my $space = $self->_ensure_space($input);
    if ( !$space ) {
        return;
    }

    return $self->_insert_or_reuse(
        {
            %{$input},
            slug     => $self->_slug($input),
            space_id => $space->{space_id},
        }
    );
}

sub _insert_or_reuse {
    my ( $self, $input ) = @_;

    my $existing = $self->_existing_category($input);
    if ($existing) {
        return { %{$existing}, idempotent => 1 };
    }

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

sub _update_once {
    my ( $self, $input ) = @_;

    my $row = $self->_visible_category( $input->{category_id} );
    if ( !$row ) {
        return;
    }

    my $updates = $self->_update_fields( $input, $row );
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

sub _ensure_space {
    my ( $self, $input ) = @_;

    my $space_id = _trim( $input->{space_id} );
    if ( length $space_id ) {
        return $self->_space_by_id($space_id);
    }

    my $first = $self->_first_space;
    if ($first) {
        return $first;
    }

    return $self->_create_default_space;
}

sub _space_by_id {
    my ( $self, $space_id ) = @_;

    return _row_hash( $self->schema->resultset('Space')->find($space_id),
        _space_columns() );
}

sub _first_space {
    my ($self) = @_;

    my $search = $self->schema->resultset('Space')->search(
        { deleted_at => undef },
        {
            order_by => [ { -asc => 'position' }, { -asc => 'slug' } ],
            rows     => $ROW_LIMIT_ONE,
        }
    );

    return _row_hash( _single($search), _space_columns() );
}

sub _create_default_space {
    my ($self) = @_;

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

sub _existing_category {
    my ( $self, $input ) = @_;

    my $search = $self->schema->resultset('Category')->search(
        {
            deleted_at => undef,
            slug       => $input->{slug},
            space_id   => $input->{space_id},
        },
        { rows => $ROW_LIMIT_ONE }
    );

    return _row_hash( _single($search), _category_columns() );
}

sub _visible_category {
    my ( $self, $category_id ) = @_;

    my $row = $self->schema->resultset('Category')->find($category_id);
    if ( !$row ) {
        return;
    }
    if ( defined _column( $row, 'deleted_at' ) ) {
        return;
    }

    return $row;
}

sub _new_category {
    my ( $self, $input ) = @_;

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

sub _update_fields {
    my ( $self, $input, $row ) = @_;

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

sub _record_write {
    my ( $self, $input ) = @_;

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

sub _slug {
    my ( undef, $input ) = @_;

    my $provided = _trim( $input->{slug} );
    if ( length $provided ) {
        return $provided;
    }

    return _slug_from_title( $input->{title} );
}

sub _slug_from_title {
    my ($title) = @_;

    my $slug = lc _trim($title);
    $slug =~ s/[^[:alnum:]]+/-/gmsx;
    $slug =~ s/\A [-]+//msx;
    $slug =~ s/[-]+ \z//msx;
    if ( length $slug ) {
        return $slug;
    }

    return $DEFAULT_SPACE_SLUG;
}

sub _visibility {
    my ($value) = @_;

    my $trimmed = _trim($value);
    if ( length $trimmed ) {
        return $trimmed;
    }

    return 'public';
}

sub _position {
    my ($value) = @_;

    my $trimmed = _trim($value);
    if ( $trimmed =~ /\A -? [[:digit:]]+ \z/msx ) {
        return int $trimmed;
    }

    return 0;
}

sub _kept_text {
    my ( $value, $current ) = @_;

    my $trimmed = _trim($value);
    if ( length $trimmed ) {
        return $trimmed;
    }

    return $current;
}

sub _kept_position {
    my ( $value, $current ) = @_;

    if ( !defined $value || !length _trim($value) ) {
        return $current;
    }

    return _position($value);
}

sub _kept_visibility {
    my ( $value, $current ) = @_;

    my $trimmed = _trim($value);
    if ( !length $trimmed ) {
        return $current;
    }

    return _visibility($trimmed);
}

sub _single {
    my ($search) = @_;

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

    return;
}

sub _list_rows {
    my ($search) = @_;

    if ( $search->can('all') ) {
        return $search->all;
    }
    if ( $search->can('rows') ) {
        return @{ $search->rows };
    }

    return;
}

sub _row_hash {
    my ( $row, @columns ) = @_;

    if ( !$row ) {
        return;
    }

    my %hash = map { $_ => _column( $row, $_ ) } @columns;

    return \%hash;
}

sub _column {
    my ( $row, $column ) = @_;

    if ( ref $row eq 'HASH' ) {
        return $row->{$column};
    }
    if ( $row && $row->can('get_column') ) {
        return $row->get_column($column);
    }

    return;
}

sub _trim {
    my ($value) = @_;

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

=head2 update_category

Updates a visible category. Returns undef when the category is missing.

=head2 list_categories

Returns visible categories ordered by position and title.

=head1 DIAGNOSTICS

Returns undef when a requested space or category cannot be resolved. Unexpected
database errors propagate to L<GPForum::Service::Admin::Workflow>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the schema, clock, and id service supplied by the composition root.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>, L<GPForum::Infrastructure::EventRecorder>,
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
