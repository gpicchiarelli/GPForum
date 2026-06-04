package GPForum::Controller::Identity;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use GPForum::Web::ErrorPayload;
use GPForum::Web::RequestPreference;
use Mojo::Base 'Mojolicious::Controller';
use Scalar::Util qw(blessed);
use Time::HiRes  qw(time);

our $VERSION = '0.001';

const my $HTTP_ACCEPTED     => 202;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_NOT_FOUND    => 404;
const my $HTTP_OK           => 200;
const my $HTTP_SERVER_ERROR => 500;
const my $HTTP_TOO_MANY     => 429;
const my $HTTP_UNAUTHORIZED => 401;
const my $PROFILE_THREADS   => 10;
const my $LOGIN_LIMIT       => 10;
const my $LOGOUT_LIMIT      => 20;
const my $PASSWORD_LIMIT    => 5;
const my $REGISTER_LIMIT    => 5;
const my $SETTINGS_LIMIT    => 60;
const my $SHORT_WINDOW      => 60;
const my $LONG_WINDOW       => 300;
const my $SESSION_SECONDS   => 2_592_000;
const my $LOCALE_COOKIE     => 'gpforum_locale';
const my $THEME_COOKIE      => 'gpforum_theme';
const my $LOCALE_COOKIE_AGE => 31_536_000;
const my %ACTION_LIMIT_FOR => (
    'identity.email_change'    => $PASSWORD_LIMIT,
    'identity.logout'          => $LOGOUT_LIMIT,
    'identity.password_change' => $PASSWORD_LIMIT,
    'identity.password_reset'  => $PASSWORD_LIMIT,
    'identity.register'        => $REGISTER_LIMIT,
    'identity.settings'        => $SETTINGS_LIMIT,
);

sub register_form {
    my ($self) = @_;

    return $self->render(
        template => 'identity/register',
        %{ $self->gp_identity_view_model->register_form },
    );
}

sub register {
    my ($self) = @_;

    return _csrf_failure($self)
      if $self->validation->csrf_protect->has_error('csrf_token');
    return _rate_limited($self)
      if !_identity_allowed( $self, 'identity.register' );

    my $result = $self->gp_registration->prepare(
        {
            username     => $self->param('username'),
            display_name => $self->param('display_name'),
            email        => $self->param('email'),
            password     => $self->param('password'),
        }
    );

    return $self->render(
        template => 'identity/register',
        status   => $HTTP_BAD_REQUEST,
        %{
            $self->gp_identity_view_model->register_form(
                errors => $result->{errors},
                values => $result->{values},
            )
        },
    ) if !$result->{ok};

    my $stored =
      $self->gp_identity_store->create_registration( $result->{registration} );

    return $self->render(
        template => 'identity/register',
        status   => $HTTP_BAD_REQUEST,
        %{
            $self->gp_identity_view_model->register_form(
                errors =>
                  _non_enumerative_registration_errors( $stored->{errors} ),
                values => $result->{values},
            )
        },
    ) if !$stored->{ok};

    return $self->render(
        template     => 'identity/register_accepted',
        status       => $HTTP_ACCEPTED,
        registration => $result->{registration},
    );
}

sub login_form {
    my ($self) = @_;

    return $self->render(
        template => 'identity/login',
        %{ $self->gp_identity_view_model->login_form },
    );
}

sub password_reset_request_form {
    my ($self) = @_;

    return $self->render(
        template => 'identity/password_reset_request',
        %{ $self->gp_identity_view_model->password_reset_request_form },
    );
}

sub request_password_reset {
    my ($self) = @_;

    my $guard = _identity_post_guard( $self, 'identity.password_reset' );
    return $guard if $guard;

    my $errors = _password_reset_request_errors(
        { identifier => $self->param('identifier') } );
    return $self->render(
        template => 'identity/password_reset_request',
        status   => $HTTP_BAD_REQUEST,
        %{
            $self->gp_identity_view_model->password_reset_request_form(
                errors => $errors,
                values => { identifier => $self->param('identifier') || q{} },
            )
        },
    ) if keys %{$errors};

    my $result = _identity_store_result(
        $self,
        'request_password_reset',
        {
            identifier      => $self->param('identifier'),
            request_address => _request_address($self),
        }
    );
    return _identity_system_failure($self) if $result->{system_failure};

    return $self->render(
        template => 'identity/password_reset_requested',
        status   => $HTTP_ACCEPTED,
    );
}

sub password_reset_form {
    my ($self) = @_;

    return $self->render(
        template => 'identity/password_reset_form',
        %{
            $self->gp_identity_view_model->password_reset_form(
                values => { token => $self->param('token') || q{} },
            )
        },
    );
}

sub reset_password {
    my ($self) = @_;

    my $guard = _identity_post_guard( $self, 'identity.password_reset' );
    return $guard if $guard;

    my $errors = _password_reset_errors(
        {
            password => $self->param('password'),
            token    => $self->param('token'),
        }
    );
    return _render_password_reset_error( $self, $errors ) if keys %{$errors};

    my $result = _identity_store_result(
        $self,
        'reset_password',
        {
            password => $self->param('password'),
            token    => $self->param('token'),
        }
    );
    return _identity_system_failure($self) if $result->{system_failure};
    return _render_password_reset_error( $self,
        { reset => 'password reset request could not be accepted' } )
      if !$result->{ok};

    return $self->render(
        template => 'identity/password_reset_completed',
        status   => $HTTP_ACCEPTED,
    );
}

sub login {
    my ($self) = @_;

    return _csrf_failure($self)
      if $self->validation->csrf_protect->has_error('csrf_token');
    return _rate_limited($self)
      if !_identity_allowed( $self, 'identity.login' );

    my $errors = _login_errors(
        {
            identifier => $self->param('identifier'),
            password   => $self->param('password'),
        }
    );

    return $self->render(
        template => 'identity/login',
        status   => $HTTP_BAD_REQUEST,
        %{
            $self->gp_identity_view_model->login_form(
                errors => $errors,
                values => { identifier => $self->param('identifier') || q{} },
            )
        },
    ) if keys %{$errors};

    my $authenticated = _authenticate_login($self);
    return _invalid_login($self) if !$authenticated->{ok};

    _apply_login_session( $self, $authenticated );
    _record_identity_audit(
        $self,
        'record_login_request',
        {
            actor_id        => $authenticated->{user_id},
            identifier      => $self->param('identifier'),
            outcome         => 'accepted',
            request_address => _request_address($self),
        }
    );

    return $self->render(
        template => 'identity/login_accepted',
        status   => $HTTP_ACCEPTED,
    );
}

sub logout {
    my ($self) = @_;

    return _csrf_failure($self)
      if $self->validation->csrf_protect->has_error('csrf_token');
    return _rate_limited($self)
      if !_identity_allowed( $self, 'identity.logout' );

    my $session_id = $self->session('session_id');
    my $user_id    = $self->session('user_id');
    _revoke_login_session( $self, $session_id, $user_id );
    _record_identity_audit(
        $self,
        'record_logout_request',
        {
            actor_id        => $user_id,
            request_address => _request_address($self),
        }
    );
    $self->session( expires => 1 );

    return $self->render(
        template => 'identity/logout_accepted',
        status   => $HTTP_ACCEPTED,
    );
}

sub set_locale {
    my ($self) = @_;

    return _csrf_failure($self)
      if $self->validation->csrf_protect->has_error('csrf_token');

    my $locale = _requested_locale($self);
    _persist_locale_preference( $self, $locale );
    _set_locale_cookie( $self, $locale );
    $self->stash( ui_locale => $locale );

    return $self->redirect_to( _safe_return_to( $self->param('return_to') ) );
}

sub set_theme {
    my ($self) = @_;

    return _csrf_failure($self)
      if $self->validation->csrf_protect->has_error('csrf_token');

    my $theme = _requested_theme($self);
    _persist_theme_preference( $self, $theme );
    _set_theme_cookie( $self, $theme );
    $self->stash( ui_theme => $theme );

    return $self->redirect_to( _safe_return_to( $self->param('return_to') ) );
}

sub settings {
    my ($self) = @_;

    my $user_id = $self->session('user_id');
    return _settings_unauthorized($self) if !$user_id;

    my $payload = _settings_payload( $self, $user_id );
    return _settings_system_failure($self) if !$payload;

    return $self->render(
        template => 'identity/settings',
        %{$payload},
        status => $HTTP_OK,
    );
}

sub update_settings {
    my ($self) = @_;

    return _csrf_failure($self)
      if $self->validation->csrf_protect->has_error('csrf_token');

    my $user_id = $self->session('user_id');
    return _settings_unauthorized($self) if !$user_id;
    return _rate_limited($self)
      if !_identity_allowed( $self, 'identity.settings' );

    my $locale = _requested_locale($self);
    my $theme  = _requested_theme($self);

    return _settings_system_failure($self)
      if !_persist_notification_preferences( $self, $user_id );

    _persist_locale_preference( $self, $locale );
    _persist_theme_preference( $self, $theme );
    _set_locale_cookie( $self, $locale );
    _set_theme_cookie( $self, $theme );
    $self->stash( ui_locale => $locale, ui_theme => $theme );

    $self->flash( success => $self->t('settings.saved') );

    return $self->redirect_to('settings');
}

sub change_password {
    my ($self) = @_;

    my $guard = _identity_post_guard( $self, 'identity.password_change' );
    return $guard if $guard;

    my $user_id = $self->session('user_id');
    return _settings_unauthorized($self) if !$user_id;

    my $result = _identity_store_result(
        $self,
        'change_password',
        {
            current_password => $self->param('current_password'),
            new_password     => $self->param('new_password'),
            user_id          => $user_id,
        }
    );
    return _identity_system_failure($self) if $result->{system_failure};
    return _identity_bad_request($self)    if !$result->{ok};

    $self->flash( success => $self->t('settings.password_changed') );

    return $self->redirect_to('settings');
}

sub request_email_change {
    my ($self) = @_;

    my $guard = _identity_post_guard( $self, 'identity.email_change' );
    return $guard if $guard;

    my $user_id = $self->session('user_id');
    return _settings_unauthorized($self) if !$user_id;

    my $result = _identity_store_result(
        $self,
        'request_email_change',
        {
            email           => $self->param('email'),
            request_address => _request_address($self),
            user_id         => $user_id,
        }
    );
    return _identity_system_failure($self) if $result->{system_failure};
    return _identity_bad_request($self)    if !$result->{ok};

    $self->flash( success => $self->t('settings.email_change_requested') );

    return $self->redirect_to('settings');
}

sub email_confirm_form {
    my ($self) = @_;

    return $self->render(
        template => 'identity/email_confirm',
        %{
            $self->gp_identity_view_model->email_confirm_form(
                values => { token => $self->param('token') || q{} },
            )
        },
    );
}

sub confirm_email_change {
    my ($self) = @_;

    my $guard = _identity_post_guard( $self, 'identity.email_change' );
    return $guard if $guard;

    my $result = _identity_store_result( $self, 'confirm_email_change',
        { token => $self->param('token') } );
    return _identity_system_failure($self) if $result->{system_failure};
    return _identity_bad_request($self)    if !$result->{ok};

    return $self->render(
        template => 'identity/email_confirmed',
        status   => $HTTP_ACCEPTED,
    );
}

sub profile {
    my ($self) = @_;

    my $profile = $self->gp_profile_reader->public_profile(
        $self->param('username'),
        {
            limit => $self->param('limit') || $PROFILE_THREADS,
            after => $self->param('after'),
        }
    );

    return _profile_not_found($self) if !$profile->{ok};

    return _render_profile( $self,
        $self->gp_identity_view_model->profile( $profile->{profile} ) );
}

sub _render_profile {
    my ( $controller, $profile ) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json   => { profile => $profile },
            status => $HTTP_OK,
        );
    }

    return $controller->render(
        template => 'identity/profile',
        profile  => $profile,
        status   => $HTTP_OK,
    );
}

sub _profile_not_found {
    my ($controller) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json   => GPForum::Web::ErrorPayload->identity_profile_not_found,
            status => $HTTP_NOT_FOUND,
        );
    }

    return $controller->render(
        template => 'identity/profile_not_found',
        status   => $HTTP_NOT_FOUND,
    );
}

sub _wants_json {
    my ($controller) = @_;

    return GPForum::Web::RequestPreference->wants_json($controller);
}

sub _login_errors {
    my ($input) = @_;

    my %errors;

    if ( !defined $input->{identifier} || !length $input->{identifier} ) {
        $errors{identifier} = 'identifier is required';
    }

    if ( !defined $input->{password} || !length $input->{password} ) {
        $errors{password} = 'password is required';
    }

    return \%errors;
}

sub _password_reset_request_errors {
    my ($input) = @_;

    my %errors;
    if ( !defined $input->{identifier} || !length $input->{identifier} ) {
        $errors{identifier} = 'identifier is required';
    }

    return \%errors;
}

sub _password_reset_errors {
    my ($input) = @_;

    my %errors;
    if ( !defined $input->{token} || !length $input->{token} ) {
        $errors{token} = 'token is required';
    }
    if ( !defined $input->{password} || !length $input->{password} ) {
        $errors{password} = 'password is required';
    }

    return \%errors;
}

sub _render_password_reset_error {
    my ( $controller, $errors ) = @_;

    return $controller->render(
        template => 'identity/password_reset_form',
        status   => $HTTP_BAD_REQUEST,
        %{
            $controller->gp_identity_view_model->password_reset_form(
                errors => $errors,
                values => { token => $controller->param('token') || q{} },
            )
        },
    );
}

sub _identity_post_guard {
    my ( $controller, $action ) = @_;

    return _csrf_failure($controller)
      if $controller->validation->csrf_protect->has_error('csrf_token');
    return _rate_limited($controller)
      if !_identity_allowed( $controller, $action );

    return;
}

sub _identity_store_result {
    my ( $controller, $method, $input ) = @_;

    my $result =
      eval { return $controller->gp_identity_store->$method($input); };
    return { ok => 0, system_failure => 1 } if $EVAL_ERROR || !$result;

    return $result;
}

sub _identity_allowed {
    my ( $controller, $action ) = @_;

    my $decision = $controller->gp_rate_limiter->check(
        {
            scope          => 'identity_http',
            actor_id       => _identity_actor($controller),
            action         => $action,
            limit          => _limit_for($action),
            window_seconds => _window_for($action),
        }
    );

    return $decision->{ok};
}

sub _identity_actor {
    my ($controller) = @_;

    return $controller->session('user_id') || _request_address($controller);
}

sub _limit_for {
    my ($action) = @_;

    return $ACTION_LIMIT_FOR{$action} if exists $ACTION_LIMIT_FOR{$action};

    return $LOGIN_LIMIT;
}

sub _window_for {
    my ($action) = @_;

    return $SHORT_WINDOW if $action eq 'identity.logout';
    return $SHORT_WINDOW if $action eq 'identity.settings';

    return $LONG_WINDOW;
}

sub _authenticate_login {
    my ($controller) = @_;

    my $result = eval {
        return $controller->gp_identity_store->authenticate_login(
            {
                identifier      => $controller->param('identifier'),
                password        => $controller->param('password'),
                request_address => _request_address($controller),
                user_agent      => $controller->req->headers->user_agent
                  || 'unknown',
            }
        );
    };

    if ($EVAL_ERROR) {
        $controller->app->log->warn("login degraded: $EVAL_ERROR");
        return { ok => 0 };
    }

    return $result;
}

sub _apply_login_session {
    my ( $controller, $authenticated ) = @_;

    my $preferred_locale =
      _login_preferred_locale( $controller, $authenticated );
    my $preferred_theme = _login_preferred_theme( $controller, $authenticated );
    my $session         = $controller->session;
    delete @{$session}{
        qw(user_id session_id login_rotation session_expires_at_epoch preferred_locale preferred_theme)
    };
    my %session_values = (
        login_rotation           => $controller->gp_id->uuid,
        session_expires_at_epoch => int( time + $SESSION_SECONDS ),
        session_id               => $authenticated->{session_id},
        user_id                  => $authenticated->{user_id},
    );
    $session_values{preferred_locale} = $preferred_locale
      if defined $preferred_locale;
    $session_values{preferred_theme} = $preferred_theme
      if defined $preferred_theme;

    $controller->session(%session_values);
    _set_locale_cookie( $controller, $preferred_locale )
      if defined $preferred_locale;
    _set_theme_cookie( $controller, $preferred_theme )
      if defined $preferred_theme;

    return;
}

sub _login_preferred_locale {
    my ( $controller, $authenticated ) = @_;

    return _authenticated_user_locale($authenticated)
      || $controller->i18n_service->supported_locale(
        $controller->cookie($LOCALE_COOKIE) )
      || $controller->ui_locale;
}

sub _authenticated_user_locale {
    my ($authenticated) = @_;

    my $user = $authenticated->{user};
    return $authenticated->{preferred_locale}
      if defined $authenticated->{preferred_locale}
      && length $authenticated->{preferred_locale};
    return $user->{preferred_locale}
      if ref $user eq 'HASH'
      && defined $user->{preferred_locale}
      && length $user->{preferred_locale};
    return $user->get_column('preferred_locale')
      if $user
      && blessed($user)
      && $user->can('get_column')
      && defined $user->get_column('preferred_locale');

    return;
}

sub _login_preferred_theme {
    my ( $controller, $authenticated ) = @_;

    my $authenticated_theme = _authenticated_user_theme($authenticated);
    return $authenticated_theme
      if $controller->ui_theme_registry->supported($authenticated_theme);

    my $cookie_theme = $controller->cookie($THEME_COOKIE);
    return $cookie_theme
      if $controller->ui_theme_registry->supported($cookie_theme);

    return $controller->ui_theme;
}

sub _authenticated_user_theme {
    my ($authenticated) = @_;

    my $user = $authenticated->{user};
    return $authenticated->{preferred_theme}
      if defined $authenticated->{preferred_theme}
      && length $authenticated->{preferred_theme};
    return $user->{preferred_theme}
      if ref $user eq 'HASH'
      && defined $user->{preferred_theme}
      && length $user->{preferred_theme};
    return $user->get_column('preferred_theme')
      if $user
      && blessed($user)
      && $user->can('get_column')
      && defined $user->get_column('preferred_theme');

    return;
}

sub _revoke_login_session {
    my ( $controller, $session_id, $user_id ) = @_;

    return if !defined $session_id || !length $session_id;

    my $result = eval {
        return $controller->gp_identity_store->revoke_session(
            {
                session_id => $session_id,
                user_id    => $user_id,
            }
        );
    };

    if ($EVAL_ERROR) {
        $controller->app->log->warn("logout revocation degraded: $EVAL_ERROR");
        return;
    }

    return $result;
}

sub _record_identity_audit {
    my ( $controller, $method, $input ) = @_;

    my $result =
      eval { return $controller->gp_identity_security_audit->$method($input); };

    if ($EVAL_ERROR) {
        $controller->app->log->warn("identity audit degraded: $EVAL_ERROR");
        return;
    }

    return $result;
}

sub _non_enumerative_registration_errors {
    my ($errors) = @_;

    return $errors if !$errors || !keys %{$errors};

    return { registration => 'registration request could not be accepted', };
}

sub _request_address {
    my ($controller) = @_;

    return $controller->tx->remote_address || 'unknown';
}

sub _rate_limited {
    my ($controller) = @_;

    _record_security_event(
        $controller,
        'rate_limit_hit',
        {
            status => $HTTP_TOO_MANY,
        }
    );

    if ( _wants_json($controller) ) {
        return $controller->render(
            json   => GPForum::Web::ErrorPayload->identity_rate_limited,
            status => $HTTP_TOO_MANY,
        );
    }

    return $controller->render(
        text   => GPForum::Web::ErrorPayload->rate_limited_text,
        status => $HTTP_TOO_MANY,
    );
}

sub _invalid_login {
    my ($controller) = @_;

    _record_security_event(
        $controller,
        'auth_denial',
        {
            action => 'identity.login',
            status => $HTTP_UNAUTHORIZED,
        }
    );

    if ( _wants_json($controller) ) {
        return $controller->render(
            json   => GPForum::Web::ErrorPayload->identity_invalid_login,
            status => $HTTP_UNAUTHORIZED,
        );
    }

    return $controller->render(
        template => 'identity/login',
        status   => $HTTP_UNAUTHORIZED,
        %{
            $controller->gp_identity_view_model->login_form(
                errors => { login => 'login request could not be accepted', },
                values => {
                    identifier => $controller->param('identifier') || q{},
                },
            )
        },
    );
}

sub _csrf_failure {
    my ($controller) = @_;

    _record_security_event(
        $controller,
        'csrf_failure',
        {
            status => $HTTP_FORBIDDEN,
        }
    );

    return $controller->render(
        text   => GPForum::Web::ErrorPayload->csrf_text,
        status => $HTTP_FORBIDDEN,
    );
}

sub _requested_locale {
    my ($controller) = @_;

    return $controller->i18n_service->supported_locale(
        $controller->param('locale') )
      || $controller->ui_locale;
}

sub _requested_theme {
    my ($controller) = @_;

    my $theme = $controller->param('theme');
    return $theme if $controller->ui_theme_registry->supported($theme);

    return $controller->ui_theme_registry->default_theme;
}

sub _settings_payload {
    my ( $controller, $user_id ) = @_;

    my $store       = $controller->gp_notification_preference_store;
    my $preferences = eval { return $store->preferences_for_user($user_id); };
    return if $EVAL_ERROR;

    return $controller->gp_identity_view_model->settings_page(
        digest_frequency_options => $store->digest_frequency_options,
        locale_options           => $controller->ui_locale_options,
        notification_preferences => $preferences,
        theme_options            => $controller->ui_theme_options,
    );
}

sub _persist_notification_preferences {
    my ( $controller, $user_id ) = @_;

    my $store       = $controller->gp_notification_preference_store;
    my $preferences = _notification_preference_input( $controller, $store );
    eval {
        return $store->set_preferences(
            {
                preferences => $preferences,
                user_id     => $user_id,
            }
        );
    };
    if ($EVAL_ERROR) {
        $controller->app->log->warn(
            "notification preference update degraded: $EVAL_ERROR");
        return 0;
    }

    return 1;
}

sub _notification_preference_input {
    my ( $controller, $store ) = @_;

    return [
        map {
            my $channel = $_;
            {
                channel          => $channel,
                digest_frequency => $controller->param(
                    'notification_' . $channel . '_digest_frequency'
                ),
                enabled =>
                  $controller->param( 'notification_' . $channel . '_enabled' )
                ? 1
                : 0,
            }
        } @{ $store->channel_names }
    ];
}

sub _persist_locale_preference {
    my ( $controller, $locale ) = @_;

    my $user_id = $controller->session('user_id');
    if ( defined $user_id && length $user_id ) {
        $controller->session( preferred_locale => $locale );
        my $result = eval {
            return $controller->gp_identity_store->update_preferred_locale(
                {
                    user_id          => $user_id,
                    preferred_locale => $locale,
                }
            );
        };
        $controller->app->log->warn(
            "locale preference update degraded: $EVAL_ERROR")
          if !$result || !$result->{ok};
    }

    return;
}

sub _persist_theme_preference {
    my ( $controller, $theme ) = @_;

    my $user_id = $controller->session('user_id');
    if ( defined $user_id && length $user_id ) {
        $controller->session( preferred_theme => $theme );
        my $result = eval {
            return $controller->gp_identity_store->update_preferred_theme(
                {
                    user_id         => $user_id,
                    preferred_theme => $theme,
                }
            );
        };
        $controller->app->log->warn(
            "theme preference update degraded: $EVAL_ERROR")
          if !$result || !$result->{ok};
    }

    return;
}

sub _set_locale_cookie {
    my ( $controller, $locale ) = @_;

    return if !defined $locale || !length $locale;

    $controller->cookie(
        $LOCALE_COOKIE => $locale,
        {
            expires  => time + $LOCALE_COOKIE_AGE,
            httponly => 1,
            path     => q{/},
            samesite => 'Lax',
        }
    );

    return;
}

sub _set_theme_cookie {
    my ( $controller, $theme ) = @_;

    return if !defined $theme || !length $theme;

    $controller->cookie(
        $THEME_COOKIE => $theme,
        {
            expires  => time + $LOCALE_COOKIE_AGE,
            httponly => 1,
            path     => q{/},
            samesite => 'Lax',
        }
    );

    return;
}

sub _safe_return_to {
    my ($return_to) = @_;

    return q{/} if !defined $return_to || !length $return_to;
    return q{/} if $return_to !~ m{\A/}msx;
    return q{/} if $return_to =~ m{\A//}msx;
    return q{/} if $return_to =~ /[\r\n]/msx;

    return $return_to;
}

sub _settings_unauthorized {
    my ($controller) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json   => GPForum::Web::ErrorPayload->unauthorized,
            status => $HTTP_UNAUTHORIZED,
        );
    }

    $controller->flash( error => $controller->t('settings.login_required') );

    return $controller->redirect_to('login');
}

sub _settings_system_failure {
    my ($controller) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json   => GPForum::Web::ErrorPayload->system_failure,
            status => $HTTP_SERVER_ERROR,
        );
    }

    return $controller->render(
        text   => GPForum::Web::ErrorPayload->system_failure()->{error},
        status => $HTTP_SERVER_ERROR,
    );
}

sub _identity_bad_request {
    my ($controller) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json   => GPForum::Web::ErrorPayload->bad_request,
            status => $HTTP_BAD_REQUEST,
        );
    }

    return $controller->render(
        text   => 'identity request could not be accepted',
        status => $HTTP_BAD_REQUEST,
    );
}

sub _identity_system_failure {
    my ($controller) = @_;

    return _settings_system_failure($controller);
}

sub _record_security_event {
    my ( $controller, $event_type, $metadata ) = @_;

    return $controller->gp_security_telemetry->record(
        $event_type,
        {
            %{$metadata}, route => _current_route_name($controller),
        }
    );
}

sub _current_route_name {
    my ($controller) = @_;

    return eval { return $controller->current_route; } || 'unknown';
}

1;

__END__

=head1 NAME

GPForum::Controller::Identity - Identity routes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/register')->to('Identity#register_form');

=head1 DESCRIPTION

Renders identity forms and delegates registration workflow preparation to
application services.

=head1 SUBROUTINES/METHODS

=head2 register_form

Renders the registration form.

=head2 register

Validates CSRF and registration input before preparing a registration record.

=head2 login_form

Renders the login form.

=head2 login

Validates CSRF and login request shape.

=head2 logout

Validates CSRF for session revocation requests.

=head2 profile

Renders a public-safe profile placeholder.

=head1 DIAGNOSTICS

Invalid CSRF tokens render C<403>; invalid submitted forms render C<400>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses helpers registered by the Mojolicious application root.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojolicious::Controller>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Login and logout persistence are wired in the next identity increment.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
