package GPForum::Test::AdminWebServices;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has binding_revokes     => sub { return []; };
has category_creates    => sub { return []; };
has category_updates    => sub { return []; };
has permission_attaches => sub { return []; };
has permission_creates  => sub { return []; };
has role_binds          => sub { return []; };
has role_creates        => sub { return []; };

sub dashboard_summary {
    return {
        async => {
            dead_letters    => _dead_letters(),
            outbox_messages => _outbox_messages(),
        },
        health     => _operations_status(),
        moderation => { reports => [ _report() ], },
        users      => _users(),
    };
}

sub list_users {
    return _users();
}

sub async_jobs {
    return {
        dead_letters    => _dead_letters(),
        outbox_messages => _outbox_messages(),
    };
}

sub operations_status {
    return _operations_status();
}

sub list_roles {
    return [
        {
            role_id     => 'role-1',
            name        => 'admin',
            description => 'Administrative governance',
            created_at  => '2026-05-23T12:00:00Z',
        },
    ];
}

sub list_permissions {
    return [
        {
            permission_id => 'permission-1',
            name          => 'admin_console.view',
            resource_type => 'admin_console',
            action        => 'view',
            created_at    => '2026-05-23T12:00:00Z',
        },
    ];
}

sub list_categories {
    return [
        {
            category_id => 'category-1',
            created_at  => '2026-05-23T12:00:00Z',
            description => 'Default category',
            position    => 0,
            slug        => 'general',
            space_id    => 'space-1',
            title       => 'General',
            updated_at  => '2026-05-23T12:00:00Z',
            visibility  => 'public',
        },
    ];
}

sub create_category {
    my ( $self, $input ) = @_;

    push @{ $self->category_creates }, $input;

    my $category;
    if ( !_missing_space( $input->{space_id} ) ) {
        $category = _category_created($input);
    }

    return $category;
}

sub update_category {
    my ( $self, $input ) = @_;

    push @{ $self->category_updates }, $input;

    my $category;
    if ( ( $input->{category_id} || q{} ) eq 'category-1' ) {
        $category = _category_updated($input);
    }

    return $category;
}

sub _missing_space {
    my ($space_id) = @_;

    return ( $space_id || q{} ) eq 'missing' ? 1 : 0;
}

sub _category_field {
    my ( $input, $name, $default ) = @_;

    if ( defined $input->{$name} && length $input->{$name} ) {
        return $input->{$name};
    }

    return $default;
}

sub _category_created {
    my ($input) = @_;

    return _category_row(
        $input,
        {
            category_id => 'category-created',
            description => q{},
            title       => $input->{title},
        }
    );
}

sub _category_updated {
    my ($input) = @_;

    my $row = _category_row(
        $input,
        {
            category_id => $input->{category_id},
            description => 'Default category',
            title       => 'General',
        }
    );
    $row->{space_id} = 'space-1';

    return $row;
}

sub _category_row {
    my ( $input, $defaults ) = @_;

    return {
        category_id => $defaults->{category_id},
        created_at  => '2026-05-23T12:00:00Z',
        description =>
          _category_field( $input, 'description', $defaults->{description} ),
        position   => _category_field( $input, 'position', 0 ),
        slug       => _category_field( $input, 'slug',     'general' ),
        space_id   => _category_field( $input, 'space_id', 'space-1' ),
        title      => _category_field( $input, 'title',    $defaults->{title} ),
        updated_at => '2026-05-23T12:00:00Z',
        visibility => _category_field( $input, 'visibility', 'public' ),
    };
}

sub create_role {
    my ( $self, $input ) = @_;

    push @{ $self->role_creates }, $input;

    return {
        role_id     => 'role-created',
        name        => $input->{name},
        description => $input->{description},
        created_at  => '2026-05-23T12:00:00Z',
    };
}

sub create_permission {
    my ( $self, $input ) = @_;

    push @{ $self->permission_creates }, $input;

    return {
        permission_id => 'permission-created',
        name          => $input->{name},
        resource_type => $input->{resource_type},
        action        => $input->{action},
        created_at    => '2026-05-23T12:00:00Z',
    };
}

sub attach_permission {
    my ( $self, $input ) = @_;

    push @{ $self->permission_attaches }, $input;

    return {
        role_id       => $input->{role_id},
        permission_id => $input->{permission_id},
        created_at    => '2026-05-23T12:00:00Z',
    };
}

sub roles_for_user {
    my ( $self, $user_id ) = @_;

    return [
        {
            binding_id         => 'binding-1',
            user_id            => $user_id,
            role_id            => 'role-1',
            resource_type      => 'global',
            resource_id        => undef,
            space_id           => undef,
            created_by_user_id => 'admin-1',
            created_at         => '2026-05-23T12:00:00Z',
            revoked_at         => undef,
        },
    ];
}

sub bind_role {
    my ( $self, $input ) = @_;

    push @{ $self->role_binds }, $input;

    return {
        ok      => 1,
        binding => {
            binding_id         => 'binding-created',
            user_id            => $input->{user_id},
            role_id            => $input->{role_id},
            resource_type      => $input->{resource_type},
            resource_id        => $input->{resource_id},
            space_id           => $input->{space_id},
            created_by_user_id => $input->{actor_user_id},
            created_at         => '2026-05-23T12:00:00Z',
            revoked_at         => undef,
        },
    };
}

sub revoke_binding {
    my ( $self, $binding_id, $actor_user_id ) = @_;

    if ( $binding_id ne 'binding-1' ) {
        return;
    }

    push @{ $self->binding_revokes },
      {
        actor_user_id => $actor_user_id,
        binding_id    => $binding_id,
      };

    return {
        binding_id         => $binding_id,
        created_by_user_id => $actor_user_id,
        revoked_at         => '2026-05-23T12:00:00Z',
    };
}

sub recent {
    return [
        {
            audit_id       => 'audit-1',
            action         => 'role_binding.created',
            actor_id       => 'admin-1',
            target_type    => 'role_binding',
            target_id      => 'binding-1',
            correlation_id => 'correlation-1',
            metadata       => { reason => 'least privilege review' },
            created_at     => '2026-05-23T12:00:00Z',
        },
    ];
}

sub for_target {
    return recent();
}

sub _users {
    return [
        {
            id                => 'user-1',
            username          => 'admin_user',
            display_name      => 'Admin User',
            email_normalized  => 'admin@example.test',
            status            => 'active',
            trust_level       => 3,
            email_verified_at => '2026-05-23T12:00:00Z',
            created_at        => '2026-05-23T12:00:00Z',
            updated_at        => '2026-05-23T12:00:00Z',
            deleted_at        => undef,
        },
    ];
}

sub _report {
    return {
        report_id                  => 'report-1',
        reporter_user_id           => 'user-2',
        target_type                => 'post',
        target_id                  => 'post-1',
        reason                     => 'spam',
        details                    => 'repeated links',
        status                     => 'open',
        assigned_moderator_user_id => undef,
        created_at                 => '2026-05-23T12:00:00Z',
        resolved_at                => undef,
        resolution                 => undef,
    };
}

sub _outbox_messages {
    return [
        {
            outbox_id        => 'outbox-1',
            event_id         => 'event-1',
            queue            => 'default',
            job_type         => 'notification.dispatch',
            idempotency_key  => 'notification.dispatch:event-1',
            available_at     => '2026-05-23T12:00:00Z',
            created_at       => '2026-05-23T12:00:00Z',
            locked_at        => undef,
            attempts         => 1,
            status           => 'pending',
            last_error       => undef,
            next_attempt_at  => '2026-05-23T12:00:00Z',
            locked_by        => undef,
            locked_until     => undef,
            attempt_count    => 1,
            last_error_class => undef,
        },
    ];
}

sub _dead_letters {
    return [
        {
            dead_letter_id  => 'dead-letter-1',
            source_table    => 'outbox_messages',
            source_id       => 'outbox-failed',
            error_class     => 'worker_failed',
            error_message   => 'retry limit exceeded',
            retry_count     => 5,
            first_failed_at => '2026-05-23T11:00:00Z',
            last_failed_at  => '2026-05-23T12:00:00Z',
        },
    ];
}

sub _operations_status {
    return {
        benchmark => {
            configured_command => 'script/benchmark-http --configured --check',
            fixture_command    => 'script/benchmark-http --fixture --check',
            persisted_baseline => 0,
            status             => 'manual',
        },
        metrics => {
            db_query_stats => { requests_observed => 2 },
            outbox         => { pending           => 1 },
            runtime        => { mode              => 'test' },
        },
        query_budget_drift => { status => 'ok' },
        query_budgets      => {
            endpoints => {
                admin_dashboard => { max_queries => 6 },
                admin_jobs      => { max_queries => 6 },
            },
        },
        readiness => {
            status => 'ok',
            checks => [
                { name => 'database', status => 'ok' },
                { name => 'runtime',  status => 'ok' },
            ],
        },
    };
}

1;
