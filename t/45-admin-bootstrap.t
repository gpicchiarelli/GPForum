# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::AdminBootstrap;
use GPForum::Service::Admin::Bootstrapper;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;

const my $EXPECTED_TESTS => 26;
const my $CREATED_ROWS   => 1;

plan tests => $EXPECTED_TESTS;

my $fixtures     = _fixtures();
my $bootstrapper = GPForum::Service::Admin::Bootstrapper->new(
    schema     => $fixtures->{schema},
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
);

my $first = $bootstrapper->bootstrap(
    {
        user_id       => 'user-1',
        actor_user_id => 'operator-1',
    }
);

is( $first->{role}{name}, 'gpforum_owner', 'bootstrap creates owner role' );
is( $first->{counts}{roles_created},
    $CREATED_ROWS, 'bootstrap reports created role' );
is(
    $first->{counts}{permissions_created},
    scalar @{ $first->{permissions} },
    'bootstrap creates each default permission'
);
is(
    $first->{counts}{role_permissions_attached},
    scalar @{ $first->{permissions} },
    'bootstrap attaches each default permission'
);
is( $first->{counts}{bindings_created},
    $CREATED_ROWS, 'bootstrap binds role to user' );
is( $first->{binding}{resource_type},
    'global', 'bootstrap uses global scope binding' );
my $expected_bootstrap_audit =
  $CREATED_ROWS + scalar @{ $first->{permissions} } * 2 + $CREATED_ROWS;
is( scalar @{ $fixtures->{audit_log}->created },
    $expected_bootstrap_audit,
    'bootstrap audits role, permissions, attachments, and binding' );
ok(
    _has_permission( $first, 'admin_console.manage' ),
    'bootstrap includes admin manage permission'
);
ok(
    _has_permission( $first, 'report.view_queue' ),
    'bootstrap includes moderation queue permission'
);
ok(
    _has_permission( $first, 'post.moderate' ),
    'bootstrap includes post moderation permission'
);
ok(
    _has_permission( $first, 'user.suspend' ),
    'bootstrap includes suspension permission'
);
ok(
    _has_permission( $first, 'privacy_rights.manage' ),
    'bootstrap includes privacy rights management permission'
);

my $repeat_bootstrap = $bootstrapper->bootstrap(
    {
        user_id       => 'user-1',
        actor_user_id => 'operator-1',
    }
);

is( $repeat_bootstrap->{counts}{roles_created},
    0, 'second bootstrap reuses role' );
is( $repeat_bootstrap->{counts}{permissions_created},
    0, 'second bootstrap reuses permissions' );
is( $repeat_bootstrap->{counts}{role_permissions_attached},
    0, 'second bootstrap reuses role permissions' );
is( $repeat_bootstrap->{counts}{bindings_created},
    0, 'second bootstrap reuses active binding' );
is( scalar @{ $fixtures->{roles}->created },
    $CREATED_ROWS, 'idempotent bootstrap avoids duplicate role rows' );
is( scalar @{ $fixtures->{role_bindings}->created },
    $CREATED_ROWS, 'idempotent bootstrap avoids duplicate bindings' );
is( scalar @{ $fixtures->{audit_log}->created },
    $expected_bootstrap_audit,
    'idempotent bootstrap avoids duplicate audit rows' );

my $command_fixtures = _fixtures();
my $command          = GPForum::Command::AdminBootstrap->new(
    schema => $command_fixtures->{schema} );
my $command_output = _capture_stdout(
    sub {
        return $command->run(
            '--user-id',       'user-2',
            '--actor-user-id', 'operator-2',
            '--role-name',     'custom_owner',
        );
    }
);

like(
    $command_output,
    qr/\A admin [ ] bootstrap [ ] role=custom_owner [ ] user=user-2/msx,
    'admin bootstrap command prints selected role and user'
);
like( $command_output, qr/created_bindings=1/msx,
    'admin bootstrap command reports created binding' );
is( scalar @{ $command_fixtures->{role_bindings}->created },
    $CREATED_ROWS, 'admin bootstrap command writes binding' );

is(
    _usage_status(
        sub {
            return $command->run('--unknown');
        }
    ),
    $EXIT_USAGE,
    'unknown admin bootstrap option fails with usage'
);
is(
    _usage_status(
        sub {
            return $command->run('--user-id');
        }
    ),
    $EXIT_USAGE,
    'admin bootstrap requires value for user id'
);

sub _fixtures {
    my $roles            = _resultset();
    my $permissions      = _resultset();
    my $role_permissions = _resultset();
    my $role_bindings    = _resultset();
    my $audit_log        = _resultset();

    return {
        roles            => $roles,
        permissions      => $permissions,
        role_permissions => $role_permissions,
        role_bindings    => $role_bindings,
        audit_log        => $audit_log,
        schema           => GPForum::Test::ModerationSchema->new(
            resultsets => {
                Role           => $roles,
                Permission     => $permissions,
                RolePermission => $role_permissions,
                RoleBinding    => $role_bindings,
                AuditLog       => $audit_log,
            },
        ),
    };
}

sub _resultset {
    return GPForum::Test::ModerationResultSet->new( filter_search => 1 );
}

sub _has_permission {
    my ( $result, $permission_name ) = @_;

    for my $permission ( @{ $result->{permissions} } ) {
        return 1
          if $permission->{permission}{name} eq $permission_name;
    }

    return 0;
}

sub _capture_stdout {
    my ($code) = @_;

    my $captured_stdout = q{};
    open my $stdout, '>', \$captured_stdout
      or croak 'failed to capture stdout';

    {
        local *STDOUT = $stdout;
        $code->();
    }

    close $stdout
      or croak 'failed to close stdout capture';

    return $captured_stdout;
}

# A usage error is no longer an exception: the command returns the documented
# exit status and prints the usage text to stderr.
sub _usage_status {
    my ($code) = @_;

    my $errors = q{};
    open my $capture, '>', \$errors or croak 'capture stderr';
    my $status;
    {
        local *STDERR = $capture;
        $status = $code->();
    }
    close $capture or croak 'close stderr';
    like( $errors, qr/Usage/msx, 'the usage text goes to stderr' );

    return $status;
}

1;
