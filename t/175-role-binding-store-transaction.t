# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Admin::RoleBindingStore;
use GPForum::Test::AdminAuditLog;
use GPForum::Test::FailingRoleBindingStore;
use GPForum::Test::FalseRetryRoleBindingStore;
use GPForum::Test::RoleBindingSchema;
use GPForum::Test::TransactionalRoleBindingSchema;

our $VERSION = '0.001';

my %BINDING_INPUT = (
    actor_user_id => 'actor-1',
    resource_id   => 'space-1',
    resource_type => 'space',
    role_id       => 'role-1',
    space_id      => 'space-1',
    user_id       => 'user-1',
);

my $schema   = GPForum::Test::TransactionalRoleBindingSchema->new;
my $recorder = GPForum::Test::AdminAuditLog->new;
my $store    = GPForum::Service::Admin::RoleBindingStore->new(
    recorder => $recorder,
    schema   => $schema,
);

my $bound = $store->bind_role( {%BINDING_INPUT} );
ok( $bound->{ok}, 'bind_role stores a new binding' );
is( $schema->transactions, 1,
    'bind_role wraps the binding and audit writes in one transaction' );
is( scalar @{ $schema->created_for('RoleBinding') },
    1, 'the role binding row is written inside the transaction' );
is( scalar @{ $recorder->rows },
    1, 'the creation audit is recorded inside the same transaction' );

my $binding_id = $bound->{binding}{binding_id};
my $revoked    = $store->revoke_binding( $binding_id, 'actor-2' );
is( $revoked->{binding_id}, $binding_id, 'revoke_binding reports the binding' );
is( $schema->transactions, 2,
    'revoke_binding wraps the update and audit writes in one transaction' );
is( scalar @{ $recorder->rows },
    2, 'the revocation audit is recorded inside the same transaction' );

# Two revocations of one binding both passed the already-revoked check when
# the binding was read without a lock; FOR UPDATE makes the second wait for
# the first and read its revoked_at (t/integration/postgres-role-admin.t).
is_deeply(
    $schema->find_attrs->[-1],
    { for => 'update' },
    'revoke_binding reads the binding FOR UPDATE'
);
my $again = $store->revoke_binding( $binding_id, 'actor-3' );
ok( $again->{idempotent}, 'a second revocation is reported, not repeated' );
is( scalar @{ $recorder->rows }, 2, 'and records no second revocation audit' );

my $plain_store = GPForum::Service::Admin::RoleBindingStore->new(
    recorder => GPForum::Test::AdminAuditLog->new,
    schema   => GPForum::Test::RoleBindingSchema->new,
);
ok(
    $plain_store->bind_role( {%BINDING_INPUT} )->{ok},
    'bind_role still writes through a schema without txn_do'
);

# A false insert result is not an exception: the retry must not rethrow a
# stale evaluation error when the insert simply returns something false.
my $false_store = GPForum::Test::FalseRetryRoleBindingStore->new(
    recorder => GPForum::Test::AdminAuditLog->new,
    schema   => GPForum::Test::TransactionalRoleBindingSchema->new,
);
my ( $false_result, $false_error );
try {
    $false_result = $false_store->bind_role( {%BINDING_INPUT} );
}
catch ($error) {
    $false_error = $error;
};
ok( !defined $false_error,
    'a false insert result does not rethrow a stale evaluation error' );
ok( !$false_result, 'the false insert result is returned to the caller' );
is( $false_store->attempts, 2, 'the id conflict triggered exactly one retry' );

# A thrown error must still propagate, driven by the evaluation error.
my $failing_store = GPForum::Test::FailingRoleBindingStore->new(
    recorder => GPForum::Test::AdminAuditLog->new,
    schema   => GPForum::Test::TransactionalRoleBindingSchema->new,
);
my ( $failed, $failure );
try {
    $failed = $failing_store->bind_role( {%BINDING_INPUT} );
}
catch ($error) {
    $failure = $error;
};
like(
    $failure,
    qr/role [ ] binding [ ] store [ ] offline/msx,
    'a thrown insert error still propagates to the caller'
);
ok( !defined $failed, 'nothing is returned when the insert throws' );

done_testing();

1;
