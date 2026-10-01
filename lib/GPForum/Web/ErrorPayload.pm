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

__END__

=head1 NAME

GPForum::Web::ErrorPayload - The error payloads controllers return, and what an HTML error page says for them.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $payload =
      GPForum::Web::ErrorPayload->not_found( error => 'thread not found' );
    # { error => 'thread not found', status => 'not_found',
    #   title => 'Not found' }

    my $page = GPForum::Web::ErrorPayload->page($payload);
    # { kind => 'not_found', detail => 'thread not found',
    #   title_key   => 'forum.error_not_found_title',
    #   message_key => 'forum.error_not_found_message' }

=head1 DESCRIPTION

One place for the shape of an error: a hash reference with C<error> (an
English message), C<status> (a stable code such as C<invalid>,
C<forbidden> or C<not_found>) and usually C<title>. JSON responses send
these strings as they are, for API clients.

An HTML error page does not show them. A payload's title and error are
English, and the common ones are internal codes such as
C<authentication required> or C<Bad CSRF token>, so C<page> maps the
payload to catalog keys for the page's title and message, and keeps the
error as detail only when it is specific to the request rather than one of
the payloads' own default messages. A CSRF failure is told apart from other
C<forbidden> payloads by its error text.

Every method can be called on the class.

=head1 SUBROUTINES/METHODS

=head2 page

Takes a payload. Returns C<< { kind, detail, title_key, message_key } >>.
C<kind> is C<csrf> when the error is the CSRF text, and the payload's
status otherwise (empty when there is none). For the kinds C<conflict>,
C<csrf>, C<error>, C<forbidden>, C<invalid>, C<not_found>,
C<rate_limited>, C<unauthorized> and C<unavailable> the keys are the kind's
catalog text (C<forum.error_internal> for C<error>, C<forum.error_KIND> for
the others) followed by C<_title> and C<_message>; any other kind gets
C<forum.error_title> and C<forum.error_default>. C<detail> is the error when
it is not empty and not a generic default message, undef otherwise.

=head2 page_text_keys

Returns an array reference of every title and message key C<page> can
name, for the test that both locales have them.

=head2 bad_request

Takes optional named C<error> (default C<invalid request>), C<title>
(default C<Invalid request>) and C<errors>. Returns a payload with status
C<invalid>; C<errors>, the per-field messages, is included only when given.

=head2 csrf_failure

Returns error C<Bad CSRF token>, status C<forbidden>, title C<Forbidden>.

=head2 csrf_text

Returns C<Bad CSRF token>, the plain-text body of a CSRF failure.

=head2 unauthorized

Returns error C<authentication required>, status C<unauthorized>, title
C<Authentication required>.

=head2 forbidden

Takes an optional named C<error> (default C<permission denied>). Returns
status C<forbidden>, title C<Forbidden>.

=head2 not_found

Takes an optional named C<error> (default C<not found>). Returns status
C<not_found>, title C<Not found>.

=head2 rate_limited

Takes optional named C<error> (default C<too many requests>) and C<title>
(default C<Too many requests>). Returns status C<rate_limited>.

=head2 rate_limited_text

Returns C<Too many requests>, the plain-text body of a rate-limited
response.

=head2 system_failure

Returns error C<internal error>, status C<error>, title C<Internal error>.

=head2 unavailable

Returns error C<service unavailable>, status C<unavailable>, title
C<Service unavailable>.

=head2 conflict

Takes optional named C<error> (default C<conflict>), C<status> (default
C<conflict>) and C<title> (default C<Conflict>). Returns the payload.

=head2 identity_rate_limited

Returns error C<too many requests>, status C<rate_limited>, no title.

=head2 identity_invalid_login

Returns error C<login request could not be accepted>, status
C<unauthorized>, no title.

=head2 identity_profile_not_found

Returns error C<profile not found>, status C<not_found>, no title.

=head1 DIAGNOSTICS

None. Every method returns a new hash reference (or string).

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None beyond L<Mojo::Base> and L<Const::Fast>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
