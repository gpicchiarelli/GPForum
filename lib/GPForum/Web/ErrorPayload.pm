package GPForum::Web::ErrorPayload;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub bad_request {
    my ( $self, %input ) = @_;

    my $payload = {
        error  => $input{error} || 'invalid request',
        status => 'invalid',
        title  => $input{title} || 'Invalid request',
    };
    $payload->{errors} = $input{errors} if exists $input{errors};

    return $payload;
}

sub csrf_failure {
    return {
        error  => 'Bad CSRF token',
        status => 'forbidden',
        title  => 'Forbidden',
    };
}

sub csrf_text {
    return 'Bad CSRF token';
}

sub unauthorized {
    return {
        error  => 'authentication required',
        status => 'unauthorized',
        title  => 'Authentication required',
    };
}

sub forbidden {
    my ( $self, %input ) = @_;

    return {
        error  => $input{error} || 'permission denied',
        status => 'forbidden',
        title  => 'Forbidden',
    };
}

sub not_found {
    my ( $self, %input ) = @_;

    return {
        error  => $input{error} || 'not found',
        status => 'not_found',
        title  => 'Not found',
    };
}

sub rate_limited {
    my ( $self, %input ) = @_;

    return {
        error  => $input{error} || 'too many requests',
        status => 'rate_limited',
        title  => $input{title} || 'Too many requests',
    };
}

sub rate_limited_text {
    return 'Too many requests';
}

sub system_failure {
    return {
        error  => 'internal error',
        status => 'error',
        title  => 'Internal error',
    };
}

sub conflict {
    my ( $self, %input ) = @_;

    return {
        error  => $input{error}  || 'conflict',
        status => $input{status} || 'conflict',
        title  => $input{title}  || 'Conflict',
    };
}

sub identity_rate_limited {
    return {
        error  => 'too many requests',
        status => 'rate_limited',
    };
}

sub identity_invalid_login {
    return {
        error  => 'login request could not be accepted',
        status => 'unauthorized',
    };
}

sub identity_profile_not_found {
    return {
        error  => 'profile not found',
        status => 'not_found',
    };
}

1;
