# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::Event;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;

our $VERSION = '0.001';

const my $SCHEMA_VERSION  => 1;
const my $TARGET_BINDING  => 'role_binding';
const my $TARGET_CATEGORY => 'category';

sub binding_audit ( $, $input ) {
    my $binding = $input->{binding};

    return {
        action     => $input->{action},
        actor_id   => $input->{actor_user_id},
        created_at => $input->{created_at},
        metadata   => {
            resource_id   => _column( $binding, 'resource_id' ),
            resource_type => _column( $binding, 'resource_type' ),
            role_id       => _column( $binding, 'role_id' ),
            space_id      => _column( $binding, 'space_id' ),
            user_id       => _column( $binding, 'user_id' ),
        },
        previous_hash  => undef,
        record_hash    => q{},
        schema_version => $SCHEMA_VERSION,
        target_id      => _column( $binding, 'binding_id' ),
        target_type    => $TARGET_BINDING,
    };
}

sub catalog_audit ( $, $input ) {
    return {
        action         => $input->{action},
        actor_id       => $input->{actor_user_id},
        created_at     => $input->{created_at},
        metadata       => $input->{metadata} || {},
        previous_hash  => undef,
        record_hash    => q{},
        schema_version => $SCHEMA_VERSION,
        target_id      => $input->{target_id},
        target_type    => $input->{target_type},
    };
}

sub category_audit ( $self, $input ) {
    my $category = $input->{category};
    my $audit    = $self->catalog_audit(
        {
            action        => $input->{action},
            actor_user_id => $input->{actor_user_id},
            created_at    => $input->{created_at},
            metadata      => {
                position   => _column( $category, 'position' ),
                slug       => _column( $category, 'slug' ),
                space_id   => _column( $category, 'space_id' ),
                title      => _column( $category, 'title' ),
                visibility => _column( $category, 'visibility' ),
            },
            target_id   => _column( $category, 'category_id' ),
            target_type => $TARGET_CATEGORY,
        }
    );
    $audit->{correlation_id} = $input->{correlation_id};

    return $audit;
}

sub category_event ( $, $input ) {
    my $category    = $input->{category};
    my $category_id = _column( $category, 'category_id' );

    return {
        actor_id          => $input->{actor_user_id},
        aggregate_id      => $category_id,
        aggregate_type    => $TARGET_CATEGORY,
        aggregate_version => _column( $category, 'version' ) || $SCHEMA_VERSION,
        causation_id      => undef,
        correlation_id    => $input->{correlation_id},
        event_type        => $input->{action},
        idempotency_key   => join( q{:}, $input->{action}, $category_id ),
        payload           => {
            category_id => $category_id,
            position    => _column( $category, 'position' ),
            slug        => _column( $category, 'slug' ),
            space_id    => _column( $category, 'space_id' ),
            title       => _column( $category, 'title' ),
            visibility  => _column( $category, 'visibility' ),
        },
        schema_version => $SCHEMA_VERSION,
    };
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

1;

__END__

=head1 NAME

GPForum::Service::Admin::Event - Admin catalog and binding audit hashes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $audit = $events->binding_audit(
        {
            action        => 'role_binding.created',
            actor_user_id => $actor_id,
            binding       => $binding,
            created_at    => $created_at,
        }
    );

=head1 DESCRIPTION

Owns AuditLog argument hashes for role bindings, role-catalog writes, and
category writes. It also owns EventLog argument hashes for category create
and update. It does not persist rows. Stores still write through
L<GPForum::Infrastructure::EventRecorder>.

=head1 SUBROUTINES/METHODS

=head2 binding_audit

Returns AuditLog arguments for a created or revoked role binding.

=head2 catalog_audit

Returns AuditLog arguments for role, permission, and attachment writes.

=head2 category_audit

Returns AuditLog arguments for category create and update.

=head2 category_event

Returns EventLog arguments for category create and update. The recorder also
writes the matching outbox row.

=head1 DIAGNOSTICS

None. Persistence errors stay in the stores.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Role-catalog and binding writes persist AuditLog only. Category writes also
emit EventLog envelopes and outbox rows.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
