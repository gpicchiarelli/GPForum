package GPForum::Controller::Identity;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my $HTTP_ACCEPTED    => 202;
const my $HTTP_BAD_REQUEST => 400;
const my $HTTP_FORBIDDEN   => 403;

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
        errors   => $stored->{errors},
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

    return $self->render(
        template => 'identity/login_accepted',
        status   => $HTTP_ACCEPTED,
    );
}

sub logout {
    my ($self) = @_;

    return _csrf_failure($self)
      if $self->validation->csrf_protect->has_error('csrf_token');

    return $self->render(
        template => 'identity/logout_accepted',
        status   => $HTTP_ACCEPTED,
    );
}

sub profile {
    my ($self) = @_;

    return $self->render(
        template => 'identity/profile',
        username => $self->param('username'),
    );
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
