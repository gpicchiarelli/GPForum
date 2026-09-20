package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::Identity::AccountStore;
use GPForum::Test::AccountStoreServices;
use GPForum::Test::FixedClock;
use GPForum::Test::Schema;
use Test::More;

our $VERSION = '0.001';

const my $PASSWORD_RESET_TRANSACTIONS => 5;

my $clock    = GPForum::Test::FixedClock->new;
my $services = GPForum::Test::AccountStoreServices->new(
    credentials => {
        'user-1' => { secret_hash => 'hashed:correct horse battery staple' },
    },
);
my $schema = GPForum::Test::Schema->new(
    users => [
        {
            email_normalized => 'giacomo@example.test',
            id               => 'user-1',
            status           => 'active',
            username         => 'giacomo',
        },
        {
            email_normalized => 'other@example.test',
            id               => 'user-2',
            status           => 'active',
            username         => 'other',
        },
        {
            email_normalized => 'gone@example.test',
            id               => 'user-deleted',
            status           => 'deleted',
            username         => 'gone',
        },
        {
            email_normalized => 'pending@example.test',
            id               => 'user-pending',
            status           => 'pending',
            username         => 'pending_user',
        },
    ],
);
my $store = _account_store( $schema, $services );

my $issued = $store->request_password_reset(
    {
        identifier      => 'GIACOMO@example.test',
        request_address => '198.51.100.1',
    }
);
ok( $issued->{ok}, 'request_password_reset succeeds for a known identifier' );
is( $issued->{token}{raw_token},
    'raw-1', 'request_password_reset returns the issued token' );
is( $services->mail_jobs->[0]{kind},
    'password_reset', 'request_password_reset queues reset mail' );
is( $services->mail_jobs->[0]{to},
    'giacomo@example.test', 'reset mail uses the member address' );
is( $services->mail_jobs->[0]{token},
    'raw-1', 'queued reset mail keeps the raw token' );
is( $services->created_tokens->[0]{token_type},
    'password_reset',
    'request_password_reset asks for a password-reset token' );
is( $services->actions->[0]{metadata}{outcome},
    'issued', 'request_password_reset audits an issued token' );

my $missing = $store->request_password_reset(
    {
        identifier      => 'missing@example.test',
        request_address => '198.51.100.1',
    }
);
ok( $missing->{ok},
    'request_password_reset succeeds for an unknown identifier' );
is( $missing->{token},
    undef, 'request_password_reset hides unknown identifiers' );
is( scalar @{ $services->mail_jobs },
    1, 'unknown identifier does not queue another mail job' );
is( $services->actions->[1]{metadata}{outcome},
    'not_found', 'request_password_reset audits unknown identifiers' );

my $deleted = $store->request_password_reset(
    {
        identifier      => 'gone',
        request_address => '198.51.100.1',
    }
);
is( $deleted->{token},
    undef, 'request_password_reset hides deleted identifiers' );

my $required = $store->reset_password( { password => q{}, token => 'raw-1' } );
is( $required->{error},
    'password_required', 'reset_password rejects an empty password' );

my $short = $store->reset_password(
    {
        password => 'too-short',
        token    => 'raw-1',
    }
);
is( $short->{error},
    'password_too_short', 'reset_password rejects a short password' );

my $bad = $store->reset_password(
    {
        password => 'new correct horse battery',
        token    => 'bad',
    }
);
is( $bad->{error}, 'invalid_token', 'reset_password rejects an invalid token' );

my $reset = $store->reset_password(
    {
        password => 'new correct horse battery',
        token    => 'raw-1',
    }
);
ok( $reset->{ok}, 'reset_password succeeds for a valid token' );
is(
    $services->credentials->{'user-1'}{secret_hash},
    'hashed:new correct horse battery',
    'reset_password rotates the credential hash'
);
is( $services->revokes->[0]{user_id},
    'user-1', 'reset_password revokes existing sessions' );
is(
    $schema->users->[0]{password_hash},
    'hashed:new correct horse battery',
    'reset_password persists the password hash'
);
is( $schema->transaction_count,
    $PASSWORD_RESET_TRANSACTIONS,
    'password reset commands run inside transactions' );

my $rotation_count = scalar @{ $services->rotations };
my $revoke_count   = scalar @{ $services->revokes };
my $reset_audits   = scalar @{ $services->actions };
my $secret_hash    = $schema->users->[0]{password_hash};
my $reset_updated  = $schema->users->[0]{updated_at};
$clock->iso8601('2026-05-23T12:30:00Z');
my $same_reset = $store->reset_password(
    {
        password => 'new correct horse battery',
        token    => 'raw-1',
    }
);
ok( $same_reset->{ok}, 'reset_password succeeds when the secret is unchanged' );
ok( $same_reset->{skipped},
    'reset_password skips rotation of an unchanged secret' );
is( scalar @{ $services->rotations },
    $rotation_count, 'unchanged reset secret does not rotate the credential' );
is( $schema->users->[0]{password_hash},
    $secret_hash, 'unchanged reset secret keeps the password hash' );
is( $schema->users->[0]{updated_at},
    $reset_updated, 'unchanged reset secret does not restamp updated_at' );
is(
    scalar @{ $services->revokes },
    $revoke_count + 1,
    'unchanged reset secret still revokes sessions'
);
is( $services->revokes->[-1]{now},
    '2026-05-23T12:30:00Z',
    'unchanged reset secret revokes sessions at the current time' );
is(
    scalar @{ $services->actions },
    $reset_audits + 1,
    'unchanged reset secret still writes completion audit'
);
$clock->iso8601('2026-05-23T12:00:00Z');

my $wrong = $store->change_password(
    {
        current_password => 'wrong password',
        new_password     => 'new correct horse battery',
        user_id          => 'user-1',
    }
);
is( $wrong->{error}, 'invalid_current_password',
    'change_password rejects the wrong current password' );

my $unknown_user = $store->change_password(
    {
        current_password => 'new correct horse battery',
        new_password     => 'even newer horse battery',
        user_id          => 'missing',
    }
);
is( $unknown_user->{error},
    'not_found', 'change_password maps a missing user to not_found' );

my $changed = $store->change_password(
    {
        current_password => 'new correct horse battery',
        new_password     => 'even newer horse battery',
        user_id          => 'user-1',
    }
);
ok( $changed->{ok},
    'change_password succeeds for a matching current password' );
is(
    $services->credentials->{'user-1'}{secret_hash},
    'hashed:even newer horse battery',
    'change_password rotates the stored credential'
);
my $password_rotations = scalar @{ $services->rotations };
my $password_audits    = scalar @{ $services->actions };
my $same_secret        = $store->change_password(
    {
        current_password => 'even newer horse battery',
        new_password     => 'even newer horse battery',
        user_id          => 'user-1',
    }
);
ok( $same_secret->{ok},
    'change_password succeeds when the secret is unchanged' );
ok( $same_secret->{skipped}, 'change_password skips an unchanged secret' );
is( scalar @{ $services->rotations },
    $password_rotations, 'unchanged secret does not rotate the credential' );
is( scalar @{ $services->actions },
    $password_audits, 'unchanged secret does not write another audit' );

my $email_required =
  $store->request_email_change( { email => q{}, user_id => 'user-1' } );
is( $email_required->{error},
    'email_required', 'request_email_change rejects an empty email' );

my $email_invalid = $store->request_email_change(
    {
        email   => 'not-an-email',
        user_id => 'user-1',
    }
);
is( $email_invalid->{error},
    'email_invalid', 'request_email_change rejects an invalid email' );

my $taken = $store->request_email_change(
    {
        email   => 'other@example.test',
        user_id => 'user-1',
    }
);
is( $taken->{error}, 'email_already_registered',
    'request_email_change rejects an email owned by another user' );

my $email = $store->request_email_change(
    {
        email           => 'NEW@example.test',
        request_address => '198.51.100.1',
        user_id         => 'user-1',
    }
);
ok( $email->{ok}, 'request_email_change succeeds for an available email' );
is( $services->created_tokens->[-1]{email_normalized},
    'new@example.test', 'request_email_change normalizes the pending email' );
is( $services->created_tokens->[-1]{token_type},
    'email_change', 'request_email_change asks for an email-change token' );

my $used = $store->confirm_email_change( { token => 'used' } );
is( $used->{error}, 'token_used', 'confirm_email_change rejects a used token' );

my $empty_email = $store->confirm_email_change( { token => 'empty-email' } );
is( $empty_email->{error},
    'invalid_token', 'confirm_email_change rejects a token without an email' );

my $missing_user = $store->confirm_email_change( { token => 'missing-user' } );
is( $missing_user->{error},
    'invalid_token',
    'confirm_email_change rejects a token for a missing user' );

my $confirmed = $store->confirm_email_change( { token => 'raw-1' } );
ok( $confirmed->{ok}, 'confirm_email_change succeeds for a valid token' );
is( $schema->users->[0]{email_normalized},
    'new@example.test', 'confirm_email_change persists the confirmed email' );
is( $schema->users->[0]{email_verified_at},
    $clock->now_iso8601, 'confirm_email_change marks the email verified' );
is(
    $services->actions->[-1]{action},
    'identity.email_change.confirmed',
    'confirm_email_change audits confirmation'
);
my $verified_at  = $schema->users->[0]{email_verified_at};
my $updated_at   = $schema->users->[0]{updated_at};
my $action_count = scalar @{ $services->actions };
$clock->iso8601('2026-05-23T13:00:00Z');
my $same_email = $store->confirm_email_change( { token => 'same-email' } );
ok( $same_email->{ok},
    'confirm_email_change succeeds for the already-confirmed address' );
ok( $same_email->{skipped}, 'already-confirmed email change is skipped' );
is( $schema->users->[0]{email_normalized},
    'new@example.test', 'already-confirmed email keeps the address' );
is( $schema->users->[0]{email_verified_at},
    $verified_at, 'already-confirmed email keeps the original timestamp' );
is( $schema->users->[0]{updated_at},
    $updated_at, 'already-confirmed email does not restamp updated_at' );
is( scalar @{ $services->actions },
    $action_count, 'already-confirmed email does not write another audit' );
$schema->find_misses(1);
my $raced_email = $store->confirm_email_change( { token => 'taken-email' } );
is( $raced_email->{error}, 'email_already_registered',
    'unique email-change race rejects a taken address' );
ok( !$raced_email->{ok}, 'unique email-change race does not confirm' );
is( $schema->users->[0]{email_normalized},
    'new@example.test', 'unique email-change race keeps the stored address' );
is( scalar @{ $services->actions },
    $action_count, 'unique email-change race does not write another audit' );
my $verified_again =
  $store->confirm_email_verification( { token => 'already-verified' } );
ok( $verified_again->{ok},
    'confirm_email_verification succeeds for an already-verified user' );
ok( $verified_again->{skipped},
    'already-verified email confirmation is skipped' );
is( $schema->users->[0]{email_verified_at},
    $verified_at, 'already-verified email keeps the original timestamp' );
is( $schema->users->[0]{updated_at},
    $updated_at, 'already-verified email does not restamp updated_at' );
is( scalar @{ $services->actions },
    $action_count, 'already-verified email does not write another audit' );
my $token_count  = scalar @{ $services->created_tokens };
my $mail_count   = scalar @{ $services->mail_jobs };
my $same_request = $store->request_email_change(
    {
        email           => 'NEW@example.test',
        request_address => '198.51.100.1',
        user_id         => 'user-1',
    }
);
ok( $same_request->{ok},
    'request_email_change succeeds for the current verified address' );
ok( $same_request->{skipped},
    'request_email_change skips the current verified address' );
is( $same_request->{token},
    undef, 'request_email_change does not issue another token' );
is( scalar @{ $services->created_tokens },
    $token_count, 'current verified address does not create another token' );
is( scalar @{ $services->mail_jobs },
    $mail_count, 'current verified address does not queue another mail job' );
is( scalar @{ $services->actions },
    $action_count, 'current verified address does not write another audit' );

my $verify = $store->request_email_verification(
    {
        identifier      => 'pending_user',
        request_address => '198.51.100.1',
    }
);
ok( $verify->{ok}, 'request_email_verification succeeds for a pending user' );
is( $services->created_tokens->[-1]{token_type},
    'email_verification',
    'request_email_verification asks for a verification token' );
is( $verify->{email_normalized},
    'pending@example.test',
    'request_email_verification returns the pending email' );

my $already_active = $store->request_email_verification(
    {
        identifier      => 'giacomo',
        request_address => '198.51.100.1',
    }
);
is( $already_active->{token},
    undef, 'request_email_verification hides an already active account' );

my $verified =
  $store->confirm_email_verification( { token => 'verify-pending' } );
ok( $verified->{ok}, 'confirm_email_verification succeeds for a valid token' );
is( $schema->users->[-1]{status},
    'active', 'confirm_email_verification activates the pending user' );
is( $schema->users->[-1]{email_verified_at},
    $clock->now_iso8601,
    'confirm_email_verification marks the email verified' );

done_testing();

sub _account_store {
    my ( $schema_arg, $services_arg ) = @_;

    return GPForum::Service::Identity::AccountStore->new(
        audit            => $services_arg,
        clock            => $clock,
        credential_store => $services_arg,
        password         => $services_arg,
        schema           => $schema_arg,
        session_store    => $services_arg,
        token_store      => $services_arg,
    );
}

1;
