package GPForum::Controller::Identity;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my $HTTP_ACCEPTED     => 202;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_NOT_FOUND    => 404;
const my $HTTP_OK           => 200;
const my $HTTP_TOO_MANY     => 429;
const my $HTTP_UNAUTHORIZED => 401;
const my $PROFILE_THREADS   => 10;
const my $LOGIN_LIMIT       => 10;
const my $LOGOUT_LIMIT      => 20;
const my $REGISTER_LIMIT    => 5;
const my $SHORT_WINDOW      => 60;
const my $LONG_WINDOW       => 300;

sub register_form {
    my ($self) = @_;

    return $self->render(
        template => 'identity/register',
        values   => {},
        errors   => {},
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
        values   => $result->{values},
        errors   => $result->{errors},
    ) if !$result->{ok};

    my $stored =
      $self->gp_identity_store->create_registration( $result->{registration} );

    return $self->render(
        template => 'identity/register',
        status   => $HTTP_BAD_REQUEST,
        values   => $result->{values},
        errors   => _non_enumerative_registration_errors( $stored->{errors} ),
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
        values   => {},
        errors   => {},
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
        values   => { identifier => $self->param('identifier') || q{} },
        errors   => $errors,
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

    return _render_profile( $self, $profile->{profile} );
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
            json   => { status => 'not_found', error => 'profile not found' },
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

    my $format = $controller->param('format') || q{};
    return 1 if $format eq 'json';

    my $accept = $controller->req->headers->accept || q{};
    return $accept =~ m{application/json}msx ? 1 : 0;
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

    return $REGISTER_LIMIT if $action eq 'identity.register';
    return $LOGOUT_LIMIT   if $action eq 'identity.logout';

    return $LOGIN_LIMIT;
}

sub _window_for {
    my ($action) = @_;

    return $SHORT_WINDOW if $action eq 'identity.logout';

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

    $controller->session(
        login_rotation => $controller->gp_id->uuid,
        session_id     => $authenticated->{session_id},
        user_id        => $authenticated->{user_id},
    );

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

    if ( _wants_json($controller) ) {
        return $controller->render(
            json => {
                error  => 'too many requests',
                status => 'rate_limited',
            },
            status => $HTTP_TOO_MANY,
        );
    }

    return $controller->render(
        text   => 'Too many requests',
        status => $HTTP_TOO_MANY,
    );
}

sub _invalid_login {
    my ($controller) = @_;

    if ( _wants_json($controller) ) {
        return $controller->render(
            json => {
                error  => 'login request could not be accepted',
                status => 'unauthorized',
            },
            status => $HTTP_UNAUTHORIZED,
        );
    }

    return $controller->render(
        template => 'identity/login',
        status   => $HTTP_UNAUTHORIZED,
        values   => { identifier => $controller->param('identifier') || q{} },
        errors   => {
            login => 'login request could not be accepted',
        },
    );
}

sub _csrf_failure {
    my ($controller) = @_;

    return $controller->render(
        text   => 'Bad CSRF token',
        status => $HTTP_FORBIDDEN,
    );
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
