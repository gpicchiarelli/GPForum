package GPForum::Test::IdentityStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $AT_CODE => 64;
const my $AT_SIGN => chr $AT_CODE;

has missing_profile  => 0;
has duplicate        => 0;
has invalid_login    => 0;
has unverified_login => 0;
has invalid_session  => 0;
has preferred_locale => undef;
has preferred_theme  => undef;
has lifecycle_calls  => sub { return []; };
has revoked          => sub { return []; };
has locale_updates   => sub { return []; };
has theme_updates    => sub { return []; };

sub create_registration {
    my ( $self, $registration ) = @_;

    push @{ $self->lifecycle_calls },
      { input => { %{$registration} }, method => 'create_registration' };

    return {
        ok     => 0,
        errors => {
            email    => 'email is already registered',
            username => 'username is already registered',
        },
      }
      if $self->duplicate;

    return { ok => 1, user => $registration->{user} };
}

sub prepare {
    my ( $self, $input ) = @_;

    my $username = defined $input->{username} ? $input->{username} : q{};
    if ( !length $username ) {
        return {
            errors => { username => 'username is required' },
            ok     => 0,
            values => { username => $username },
        };
    }

    return {
        ok           => 1,
        registration => { user     => { username => $username } },
        values       => { username => $username },
    };
}

sub authenticate_login {
    my ( $self, $input ) = @_;

    push @{ $self->lifecycle_calls },
      {
        input  => { identifier => $input->{identifier} },
        method => 'authenticate_login'
      };

    return { ok => 0, error => 'invalid_credentials' }
      if $self->invalid_login;
    return { ok => 0, error => 'unverified' }
      if $self->unverified_login;

    return {
        ok         => 1,
        session    => { session_id => 'session-1', user_id => 'user-1' },
        session_id => 'session-1',
        user       => {
            id               => 'user-1',
            preferred_locale => $self->preferred_locale,
            preferred_theme  => $self->preferred_theme,
            username         => 'giacomo_forum',
        },
        user_id => 'user-1',
    };
}

sub update_preferred_locale {
    my ( $self, $input ) = @_;

    $self->preferred_locale( $input->{preferred_locale} );
    push @{ $self->lifecycle_calls },
      { input => { %{$input} }, method => 'update_preferred_locale' };
    push @{ $self->locale_updates }, { %{$input} };

    return {
        ok               => 1,
        preferred_locale => $self->preferred_locale,
    };
}

sub preferred_locale_for_user {
    my ( $self, $input ) = @_;

    return {
        ok               => 1,
        preferred_locale => $self->preferred_locale,
    };
}

sub update_preferred_theme {
    my ( $self, $input ) = @_;

    $self->preferred_theme( $input->{preferred_theme} );
    push @{ $self->lifecycle_calls },
      { input => { %{$input} }, method => 'update_preferred_theme' };
    push @{ $self->theme_updates }, { %{$input} };

    return {
        ok              => 1,
        preferred_theme => $self->preferred_theme,
    };
}

sub preferred_theme_for_user {
    my ( $self, $input ) = @_;

    return {
        ok              => 1,
        preferred_theme => $self->preferred_theme,
    };
}

sub revoke_session {
    my ( $self, $input ) = @_;

    push @{ $self->lifecycle_calls },
      { input => { %{$input} }, method => 'revoke_session' };
    push @{ $self->revoked }, { %{$input} };

    return {
        ok      => 1,
        session => {
            session_id => $input->{session_id},
            user_id    => $input->{user_id},
        },
    };
}

sub validate_session {
    my ( $self, $input ) = @_;

    return { ok => 0, error => 'expired' } if $self->invalid_session;

    return {
        ok      => 1,
        session => {
            session_id => $input->{session_id},
            user_id    => $input->{user_id},
        },
    };
}

sub request_password_reset {
    my ( $self, $input ) = @_;

    push @{ $self->lifecycle_calls },
      { input => { %{$input} }, method => 'request_password_reset' };

    return {
        email_normalized => 'giacomo@example.test',
        ok               => 1,
        token            => {
            expires_at => '2026-05-23T13:00:00Z',
            raw_token  => 'reset-token',
            token_id   => 'identity-token-1',
        },
    };
}

sub reset_password {
    my ( $self, $input ) = @_;

    push @{ $self->lifecycle_calls },
      { input => { %{$input} }, method => 'reset_password' };

    return { ok => 1 };
}

sub change_password {
    my ( $self, $input ) = @_;

    push @{ $self->lifecycle_calls },
      { input => { %{$input} }, method => 'change_password' };

    return { ok => 1 };
}

sub request_email_change {
    my ( $self, $input ) = @_;

    push @{ $self->lifecycle_calls },
      { input => { %{$input} }, method => 'request_email_change' };

    return {
        email_normalized => $input->{email} || 'new@example.test',
        ok               => 1,
        token            => {
            expires_at => '2026-05-24T12:00:00Z',
            raw_token  => 'email-token',
            token_id   => 'identity-token-2',
        },
    };
}

sub request_email_verification {
    my ( $self, $input ) = @_;

    push @{ $self->lifecycle_calls },
      { input => { %{$input} }, method => 'request_email_verification' };

    return {
        email_normalized => 'giacomo@example.test',
        ok               => 1,
        token            => {
            expires_at => '2026-05-24T12:00:00Z',
            raw_token  => 'verify-token',
            token_id   => 'identity-token-3',
        },
    };
}

sub confirm_email_verification {
    my ( $self, $input ) = @_;

    push @{ $self->lifecycle_calls },
      { input => { %{$input} }, method => 'confirm_email_verification' };

    return { ok => 1 };
}

sub confirm_email_change {
    my ( $self, $input ) = @_;

    push @{ $self->lifecycle_calls },
      { input => { %{$input} }, method => 'confirm_email_change' };

    return { ok => 1 };
}

sub public_profile {
    my ( $self, $username, $options ) = @_;

    return { ok => 0, error => 'not_found' }
      if $self->missing_profile || $username eq 'missing';

    return {
        ok      => 1,
        profile => {
            user => {
                user_id       => 'user-1',
                username      => 'giacomo_forum',
                display_name  => 'Giacomo Picchiarelli',
                status        => 'active',
                trust_level   => 2,
                created_at    => '2026-05-23T12:00:00Z',
                updated_at    => '2026-05-23T12:00:00Z',
                profile_label => $AT_SIGN . 'giacomo_forum',
            },
            trust => {
                score         => 55,
                trust_level   => 2,
                calculated_at => '2026-05-23T12:00:00Z',
                version       => 1,
                badge         => 'Trusted contributor',
            },
            counts => {
                public_threads => 1,
                public_replies => 1,
                total_public   => 2,
            },
            threads => {
                items => [
                    {
                        thread_id        => 'thread-1',
                        category_id      => 'category-1',
                        author_user_id   => 'user-1',
                        title            => 'Welcome',
                        slug             => 'welcome',
                        visibility       => 'public',
                        moderation_state => 'visible',
                        last_activity_at => '2026-05-23T12:00:00Z',
                        created_at       => '2026-05-23T11:00:00Z',
                    },
                ],
                next_cursor => 'profile-cursor',
            },
            replies => {
                items => [
                    {
                        post_id          => 'post-2',
                        thread_id        => 'thread-1',
                        author_user_id   => 'user-1',
                        position         => 2,
                        visibility       => 'public',
                        moderation_state => 'visible',
                        thread_title     => 'Welcome',
                        thread_slug      => 'welcome',
                        created_at       => '2026-05-23T12:30:00Z',
                    },
                ],
                next_cursor => undef,
            },
        },
    };
}

1;
