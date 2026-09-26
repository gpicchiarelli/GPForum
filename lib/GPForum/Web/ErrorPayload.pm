# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::ErrorPayload;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $CSRF_TEXT => 'Bad CSRF token';

# What an HTML error page says for each kind of failure. A payload's title and
# error are English, and the common ones are internal codes -- "authentication
# required", "Bad CSRF token" -- so the page shows these catalog texts
# instead; the JSON payload keeps its stable strings for API clients.
const my %PAGE_TEXT => (
    conflict     => 'forum.error_conflict',
    csrf         => 'forum.error_csrf',
    error        => 'forum.error_internal',
    forbidden    => 'forum.error_forbidden',
    invalid      => 'forum.error_invalid',
    not_found    => 'forum.error_not_found',
    rate_limited => 'forum.error_rate_limited',
    unauthorized => 'forum.error_unauthorized',
    unavailable  => 'forum.error_unavailable',
);

# The payloads' own default messages, which the page texts above already
# say better. Anything else is specific to the request -- "already replayed
# as outbox ..." -- and the page keeps it as detail.
const my %GENERIC_ERROR => map { $_ => 1 } (
    $CSRF_TEXT,
    'authentication required',
    'conflict',
    'idempotency conflict',
    'internal error',
    'invalid request',
    'not found',
    'permission denied',
    'service unavailable',
    'too many requests',
);

sub page ( $class, $payload ) {
    my $error = $payload->{error};
    my $kind =
      defined $error && $error eq $CSRF_TEXT ? 'csrf' : $payload->{status}
      // q{};
    my $text = exists $PAGE_TEXT{$kind} ? $PAGE_TEXT{$kind} : undef;

    return {
        detail => defined $error
          && length $error
          && !exists $GENERIC_ERROR{$error} ? $error : undef,
        kind        => $kind,
        message_key => $text ? "${text}_message" : 'forum.error_default',
        title_key   => $text ? "${text}_title"   : 'forum.error_title',
    };
}

# Every catalog key a page can name, for the test that both locales have them.
sub page_text_keys ($class) {
    return [ map { ( "${_}_message", "${_}_title" ) } sort values %PAGE_TEXT ];
}

sub bad_request ( $self, %input ) {
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
        error  => $CSRF_TEXT,
        status => 'forbidden',
        title  => 'Forbidden',
    };
}

sub csrf_text {
    return $CSRF_TEXT;
}

sub unauthorized {
    return {
        error  => 'authentication required',
        status => 'unauthorized',
        title  => 'Authentication required',
    };
}

sub forbidden ( $self, %input ) {
    return {
        error  => $input{error} || 'permission denied',
        status => 'forbidden',
        title  => 'Forbidden',
    };
}

sub not_found ( $self, %input ) {
    return {
        error  => $input{error} || 'not found',
        status => 'not_found',
        title  => 'Not found',
    };
}

sub rate_limited ( $self, %input ) {
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

sub unavailable {
    return {
        error  => 'service unavailable',
        status => 'unavailable',
        title  => 'Service unavailable',
    };
}

sub conflict ( $self, %input ) {
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
