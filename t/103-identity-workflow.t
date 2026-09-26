# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Identity::Workflow;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::IdentityStore;
use Test::More;

our $VERSION = '0.001';

my $services = GPForum::Test::IdentityStore->new;
my $workflow = GPForum::Service::Identity::Workflow->new(
    registration => $services,
    store        => $services,
);

my $registered = $workflow->register(
    {
        command_id => 'register-cmd-1',
        username   => 'giacomo',
    }
);
ok( $registered->{ok}, 'register succeeds for a valid username' );
is( $registered->{stored}{registration}{user}{username},
    'giacomo', 'register returns the prepared registration' );

my $missing_command = $workflow->register( { username => 'giacomo' } );
is( $missing_command->{status},
    'invalid', 'register rejects a missing command_id' );
is(
    $missing_command->{errors}{command_id},
    'command_id is required',
    'register names the missing command_id'
);

my $missing_username = $workflow->register(
    {
        command_id => 'register-cmd-2',
        username   => q{},
    }
);
is( $missing_username->{status},
    'invalid', 'register rejects an empty username' );
is(
    $missing_username->{errors}{username},
    'username is required',
    'register names the missing username'
);

$services->duplicate(1);
my $duplicate = $workflow->register(
    {
        command_id => 'register-cmd-3',
        username   => 'giacomo',
    }
);
is( $duplicate->{status}, 'invalid',
    'register hides duplicate account errors' );
is(
    $duplicate->{errors}{registration},
    'registration request could not be accepted',
    'register does not enumerate existing accounts'
);
$services->duplicate(0);

my $logged_in = $workflow->login(
    {
        command_id => 'login-cmd-1',
        identifier => 'giacomo',
        password   => 'secret-password',
    }
);
ok( $logged_in->{ok}, 'login succeeds for known credentials' );
is( $logged_in->{stored}{user_id}, 'user-1', 'login returns the stored user' );
ok( !exists $logged_in->{stored}{user},
    'login strips the raw user row from the result' );

# A login needs no command id: it never goes through the command log.
ok(
    $workflow->login(
        { identifier => 'giacomo', password => 'secret-password' }
    )->{ok},
    'login needs no command_id'
);

my $missing_password = $workflow->login(
    {
        command_id => 'login-cmd-2',
        identifier => 'giacomo',
        password   => q{},
    }
);
is( $missing_password->{status}, 'invalid', 'login rejects an empty password' );

$services->invalid_login(1);
my $rejected = $workflow->login(
    {
        command_id => 'login-cmd-3',
        identifier => 'giacomo',
        password   => 'secret-password',
    }
);
is( $rejected->{status},
    'rejected', 'login maps invalid credentials to rejected' );
$services->invalid_login(0);

$services->unverified_login(1);
my $unverified = $workflow->login(
    {
        command_id => 'login-cmd-4',
        identifier => 'giacomo',
        password   => 'secret-password',
    }
);
is( $unverified->{status},
    'rejected', 'login maps pending accounts to rejected' );
is( $unverified->{error},
    'unverified', 'login names unverified pending accounts' );
$services->unverified_login(0);

my $logged_out = $workflow->logout(
    {
        command_id => 'logout-cmd-1',
        session_id => 'session-1',
        user_id    => 'user-1',
    }
);
ok( $logged_out->{ok}, 'logout revokes a known session' );

my $missing_logout_command =
  $workflow->logout( { session_id => 'session-1', user_id => 'user-1' } );
is( $missing_logout_command->{status},
    'invalid', 'logout rejects a missing command_id' );

my $skipped = $workflow->logout(
    {
        command_id => 'logout-skip-1',
        session_id => q{},
        user_id    => 'user-1',
    }
);
ok( $skipped->{ok}, 'logout succeeds when no session id is present' );
ok( $skipped->{stored}{skipped}, 'logout skips revocation without a session' );

my $reset_requested = $workflow->request_password_reset(
    {
        command_id => 'reset-cmd-1',
        identifier => 'giacomo@example.test',
    }
);
ok( $reset_requested->{ok},
    'request_password_reset succeeds for an identifier' );
ok(
    !defined $reset_requested->{stored}{token}{raw_token},
    'request_password_reset hides the raw token from callers'
);
is( $services->lifecycle_calls->[-1]{method},
    'request_password_reset',
    'request_password_reset persists through the store' );

my $missing_reset_command =
  $workflow->request_password_reset( { identifier => 'giacomo@example.test' } );
is( $missing_reset_command->{status},
    'invalid', 'request_password_reset rejects a missing command_id' );
is(
    $missing_reset_command->{errors}{command_id},
    'command_id is required',
    'request_password_reset names the missing command_id'
);

my $missing_identifier = $workflow->request_password_reset(
    {
        command_id => 'reset-cmd-2',
        identifier => q{},
    }
);
is( $missing_identifier->{status},
    'invalid', 'request_password_reset rejects an empty identifier' );

my $reset = $workflow->reset_password(
    {
        command_id => 'reset-complete-1',
        password   => 'new-secret-password',
        token      => 'reset-token',
    }
);
ok( $reset->{ok}, 'reset_password succeeds for a complete command' );

my $missing_reset_complete_command = $workflow->reset_password(
    {
        password => 'new-secret-password',
        token    => 'reset-token',
    }
);
is( $missing_reset_complete_command->{status},
    'invalid', 'reset_password rejects a missing command_id' );
is(
    $missing_reset_complete_command->{errors}{command_id},
    'command_id is required',
    'reset_password names the missing command_id'
);

my $changed = $workflow->change_password(
    {
        command_id       => 'password-change-1',
        current_password => 'old-secret',
        new_password     => 'new-secret-password',
        user_id          => 'user-1',
    }
);
ok( $changed->{ok}, 'change_password succeeds for a known user' );

my $missing_password_command = $workflow->change_password(
    {
        current_password => 'old-secret',
        new_password     => 'new-secret-password',
        user_id          => 'user-1',
    }
);
is( $missing_password_command->{status},
    'invalid', 'change_password rejects a missing command_id' );

my $email = $workflow->request_email_change(
    {
        command_id => 'email-cmd-1',
        email      => 'new@example.test',
        user_id    => 'user-1',
    }
);
ok( $email->{ok}, 'request_email_change succeeds for a known user' );

my $missing_email_command = $workflow->request_email_change(
    {
        email   => 'new@example.test',
        user_id => 'user-1',
    }
);
is( $missing_email_command->{status},
    'invalid', 'request_email_change rejects a missing command_id' );

my $confirmed = $workflow->confirm_email_change(
    {
        command_id => 'email-complete-1',
        token      => 'email-token',
    }
);
ok( $confirmed->{ok}, 'confirm_email_change succeeds for a known token' );

my $missing_confirm_command =
  $workflow->confirm_email_change( { token => 'email-token' } );
is( $missing_confirm_command->{status},
    'invalid', 'confirm_email_change rejects a missing command_id' );

my $verify_requested = $workflow->request_email_verification(
    {
        command_id => 'verify-cmd-1',
        identifier => 'giacomo',
    }
);
ok( $verify_requested->{ok},
    'request_email_verification succeeds for an identifier' );

my $missing_verify_command =
  $workflow->request_email_verification( { identifier => 'giacomo' } );
is( $missing_verify_command->{status},
    'invalid', 'request_email_verification rejects a missing command_id' );

my $verified = $workflow->verify_email(
    {
        command_id => 'verify-complete-1',
        token      => 'verify-token',
    }
);
ok( $verified->{ok}, 'verify_email succeeds for a known token' );

my $missing_verify_complete_command =
  $workflow->verify_email( { token => 'verify-token' } );
is( $missing_verify_complete_command->{status},
    'invalid', 'verify_email rejects a missing command_id' );

my $missing_verify = $workflow->verify_email(
    {
        command_id => 'verify-complete-2',
        token      => q{},
    }
);
is( $missing_verify->{status},
    'invalid', 'verify_email rejects an empty token' );

my $locale = $workflow->update_preferred_locale(
    {
        command_id       => 'locale-cmd-1',
        preferred_locale => 'it',
        user_id          => 'user-1',
    }
);
ok( $locale->{ok}, 'update_preferred_locale succeeds for a known user' );
is( $locale->{stored}{preferred_locale},
    'it', 'update_preferred_locale stores the requested locale' );

my $missing_locale_command = $workflow->update_preferred_locale(
    {
        preferred_locale => 'it',
        user_id          => 'user-1',
    }
);
is( $missing_locale_command->{status},
    'invalid', 'update_preferred_locale rejects a missing command_id' );

my $missing_locale = $workflow->update_preferred_locale(
    {
        command_id       => 'locale-cmd-2',
        preferred_locale => q{},
        user_id          => 'user-1',
    }
);
is( $missing_locale->{status},
    'invalid', 'update_preferred_locale rejects an empty locale' );

my $theme = $workflow->update_preferred_theme(
    {
        command_id      => 'theme-cmd-1',
        preferred_theme => 'high_contrast',
        user_id         => 'user-1',
    }
);
ok( $theme->{ok}, 'update_preferred_theme succeeds for a known user' );
is( $theme->{stored}{preferred_theme},
    'high_contrast', 'update_preferred_theme stores the requested theme' );

my $missing_theme_command = $workflow->update_preferred_theme(
    {
        preferred_theme => 'high_contrast',
        user_id         => 'user-1',
    }
);
is( $missing_theme_command->{status},
    'invalid', 'update_preferred_theme rejects a missing command_id' );

my $missing_theme = $workflow->update_preferred_theme(
    {
        command_id      => 'theme-cmd-2',
        preferred_theme => q{},
        user_id         => 'user-1',
    }
);
is( $missing_theme->{status},
    'invalid', 'update_preferred_theme rejects an empty theme' );

my $idempotency = GPForum::Test::CommandIdempotency->new;
my $commanded   = GPForum::Service::Identity::Workflow->new(
    command_idempotency => $idempotency,
    registration        => $services,
    store               => $services,
);
my $issued_count = scalar @{ $services->lifecycle_calls };
my $issued       = $commanded->request_password_reset(
    {
        command_id => 'reset-replay-1',
        identifier => 'giacomo@example.test',
    }
);
ok( $issued->{ok}, 'commanded password reset records a command' );
is( $idempotency->last_input->{command_type},
    'identity.password_reset',
    'password reset uses the identity.password_reset command type' );

my $replay_workflow = GPForum::Service::Identity::Workflow->new(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        replay_response => $issued,
    ),
    registration => $services,
    store        => $services,
);
my $replayed = $replay_workflow->request_password_reset(
    {
        command_id => 'reset-replay-1',
        identifier => 'giacomo@example.test',
    }
);
is_deeply( $replayed, $issued, 'password reset replays the recorded result' );
is(
    scalar @{ $services->lifecycle_calls },
    $issued_count + 1,
    'password reset replay does not issue a second token'
);

my $conflicted = GPForum::Service::Identity::Workflow->new(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        conflict => 1,
    ),
    registration => $services,
    store        => $services,
)->request_password_reset(
    {
        command_id => 'reset-conflict-1',
        identifier => 'other@example.test',
    }
);
is( $conflicted->{status}, 'conflict',
    'password reset rejects a reused command_id for another request' );

my $issued_register = $commanded->register(
    {
        command_id => 'register-replay-1',
        username   => 'giacomo',
    }
);
ok( $issued_register->{ok}, 'commanded register records a command' );
is( $idempotency->last_input->{command_type},
    'identity.register', 'register uses the identity.register command type' );
is_deeply(
    $idempotency->last_input->{request},
    {
        email    => q{},
        username => 'giacomo',
    },
    'register command log omits the password'
);

my $register_count    = _registration_writes($services);
my $replayed_register = GPForum::Service::Identity::Workflow->new(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        replay_response => $issued_register,
    ),
    registration => $services,
    store        => $services,
)->register(
    {
        command_id => 'register-replay-1',
        username   => 'giacomo',
    }
);
is_deeply( $replayed_register, $issued_register,
    'register replays the recorded result' );
is( _registration_writes($services),
    $register_count,
    'register replay does not persist a second pending account' );

my $conflicted_register = GPForum::Service::Identity::Workflow->new(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        conflict => 1,
    ),
    registration => $services,
    store        => $services,
)->register(
    {
        command_id => 'register-conflict-1',
        username   => 'other',
    }
);
is( $conflicted_register->{status},
    'conflict', 'register rejects a reused command_id for another request' );

my $issued_login = $commanded->login(
    {
        command_id => 'login-replay-1',
        identifier => 'giacomo',
        password   => 'secret-password',
    }
);
ok( $issued_login->{ok}, 'a login succeeds with the command log wired' );
isnt( ( $idempotency->last_input // {} )->{command_type},
    'identity.login', 'but never records itself in it' );

# A login is never answered from the command log. Replaying a stored login
# handed its session, token included, to anyone who sent the same command id
# and identifier -- whatever the password.
my $login_count    = _store_calls( $services, 'authenticate_login' );
my $replay_attempt = GPForum::Service::Identity::Workflow->new(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        replay_response => $issued_login,
    ),
    registration => $services,
    store        => $services,
)->login(
    {
        command_id => 'login-replay-1',
        identifier => 'giacomo',
        password   => 'secret-password',
    }
);
is(
    _store_calls( $services, 'authenticate_login' ),
    $login_count + 1,
    'a login with a known command id checks the password'
);
ok( $replay_attempt->{ok}, 'and signs in on its own merits' );

my $issued_reset = $commanded->reset_password(
    {
        command_id => 'reset-complete-replay-1',
        password   => 'new-secret-password',
        token      => 'reset-token',
    }
);
ok( $issued_reset->{ok},
    'commanded password reset complete records a command' );
is(
    $idempotency->last_input->{command_type},
    'identity.password_reset_complete',
'password reset complete uses the identity.password_reset_complete command type'
);
is_deeply(
    $idempotency->last_input->{request},
    { token => 'reset-token' },
    'password reset complete command log omits the new password'
);
ok( !exists $issued_reset->{stored}{user},
    'password reset complete strips the raw user row from the result' );

my $reset_count    = _store_calls( $services, 'reset_password' );
my $replayed_reset = GPForum::Service::Identity::Workflow->new(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        replay_response => $issued_reset,
    ),
    registration => $services,
    store        => $services,
)->reset_password(
    {
        command_id => 'reset-complete-replay-1',
        password   => 'new-secret-password',
        token      => 'reset-token',
    }
);
is_deeply( $replayed_reset, $issued_reset,
    'password reset complete replays the recorded result' );
is( _store_calls( $services, 'reset_password' ),
    $reset_count,
    'password reset complete replay does not consume the token twice' );

my $conflicted_reset = GPForum::Service::Identity::Workflow->new(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        conflict => 1,
    ),
    registration => $services,
    store        => $services,
)->reset_password(
    {
        command_id => 'reset-complete-conflict-1',
        password   => 'other-secret-password',
        token      => 'other-token',
    }
);
is( $conflicted_reset->{status},
    'conflict',
    'password reset complete rejects a reused command_id for another request' );

_replay_commanded_write(
    {
        commanded    => $commanded,
        command_type => 'identity.email_verification_complete',
        idempotency  => $idempotency,
        input        => {
            command_id => 'verify-complete-replay-1',
            token      => 'verify-token',
        },
        method       => 'verify_email',
        replay_note  => 'verify_email replay does not consume the token twice',
        request      => { token => 'verify-token' },
        request_note => 'verify_email command log stores only the token',
        services     => $services,
        store_method => 'confirm_email_verification',
    }
);
_replay_commanded_write(
    {
        commanded    => $commanded,
        command_type => 'identity.email_change_complete',
        idempotency  => $idempotency,
        input        => {
            command_id => 'email-complete-replay-1',
            token      => 'email-token',
        },
        method      => 'confirm_email_change',
        replay_note =>
          'confirm_email_change replay does not consume the token twice',
        request      => { token => 'email-token' },
        request_note =>
          'confirm_email_change command log stores only the token',
        services     => $services,
        store_method => 'confirm_email_change',
    }
);
_replay_commanded_write(
    {
        commanded    => $commanded,
        command_type => 'identity.password_change',
        idempotency  => $idempotency,
        input        => {
            command_id       => 'password-change-replay-1',
            current_password => 'old-secret',
            new_password     => 'new-secret-password',
            user_id          => 'user-1',
        },
        method       => 'change_password',
        replay_note  => 'change_password replay does not rotate twice',
        request      => { user_id => 'user-1' },
        request_note => 'change_password command log omits the passwords',
        services     => $services,
        store_method => 'change_password',
    }
);
_replay_commanded_write(
    {
        commanded    => $commanded,
        command_type => 'identity.logout',
        idempotency  => $idempotency,
        input        => {
            command_id => 'logout-replay-1',
            session_id => 'session-1',
            user_id    => 'user-1',
        },
        method      => 'logout',
        replay_note => 'logout replay does not revoke the session twice',
        request     => {
            session_id => 'session-1',
            user_id    => 'user-1',
        },
        request_note => 'logout command log stores session_id and user_id',
        services     => $services,
        store_method => 'revoke_session',
    }
);
_replay_commanded_write(
    {
        commanded    => $commanded,
        command_type => 'identity.locale_change',
        idempotency  => $idempotency,
        input        => {
            command_id       => 'locale-replay-1',
            preferred_locale => 'it',
            user_id          => 'user-1',
        },
        method      => 'update_preferred_locale',
        replay_note => 'locale change replay does not persist twice',
        request     => {
            preferred_locale => 'it',
            user_id          => 'user-1',
        },
        request_note => 'locale command log stores locale and user_id',
        services     => $services,
        stored       => {
            ok               => 1,
            preferred_locale => 'it',
        },
        store_method => 'update_preferred_locale',
    }
);
_replay_commanded_write(
    {
        commanded    => $commanded,
        command_type => 'identity.theme_change',
        idempotency  => $idempotency,
        input        => {
            command_id      => 'theme-replay-1',
            preferred_theme => 'high_contrast',
            user_id         => 'user-1',
        },
        method      => 'update_preferred_theme',
        replay_note => 'theme change replay does not persist twice',
        request     => {
            preferred_theme => 'high_contrast',
            user_id         => 'user-1',
        },
        request_note => 'theme command log stores theme and user_id',
        services     => $services,
        stored       => {
            ok              => 1,
            preferred_theme => 'high_contrast',
        },
        store_method => 'update_preferred_theme',
    }
);

done_testing();

sub _registration_writes {
    my ($store) = @_;

    return _store_calls( $store, 'create_registration' );
}

sub _store_calls {
    my ( $store, $method ) = @_;

    return scalar grep { $_->{method} eq $method } @{ $store->lifecycle_calls };
}

sub _replay_commanded_write {
    my ($job) = @_;

    my $method       = $job->{method};
    my $write_issued = $job->{commanded}->$method( $job->{input} );
    ok( $write_issued->{ok}, "$method records a command" );
    is( $job->{idempotency}->last_input->{command_type},
        $job->{command_type}, "$method uses $job->{command_type}" );
    is_deeply(
        $write_issued->{stored},
        $job->{stored} || { ok => 1 },
        "$method records a public stored result"
    );
    is_deeply( $job->{idempotency}->last_input->{request},
        $job->{request}, $job->{request_note}, );
    my $write_count    = _store_calls( $job->{services}, $job->{store_method} );
    my $write_replayed = GPForum::Service::Identity::Workflow->new(
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            replay_response => $write_issued,
        ),
        registration => $job->{services},
        store        => $job->{services},
    )->$method( $job->{input} );
    is_deeply( $write_replayed, $write_issued,
        "$method replays the recorded result" );
    is( _store_calls( $job->{services}, $job->{store_method} ),
        $write_count, $job->{replay_note} );
    my $consume_conflict = GPForum::Service::Identity::Workflow->new(
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            conflict => 1,
        ),
        registration => $job->{services},
        store        => $job->{services},
    )->$method( $job->{input} );
    is( $consume_conflict->{status},
        'conflict', "$method rejects a reused command_id for another request" );

    return;
}

1;
