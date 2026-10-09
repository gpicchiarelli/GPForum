# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::OperationsAccess;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Service::Operations::MetricsTokens;
use GPForum::Web::Access;

our $VERSION = '0.001';

const my $BEARER_PREFIX        => 'Bearer';
const my $HTTP_UNAUTHORIZED    => 401;
const my $METRICS_TOKEN_HEADER => 'X-GPForum-Metrics-Token';
const my $UNAUTHORIZED_ERROR   => 'metrics token required';
const my $UNAUTHORIZED_STATUS  => 'unauthorized';

has access => sub { return GPForum::Web::Access->new; };

sub metrics_token_header {
    return $METRICS_TOKEN_HEADER;
}

# The tokens are the ones the environment file names now, for the
# configuration the service started with (ADR 0124): a rotation, or its
# --finish, needs no restart.
sub metrics_input ( $self, $headers, $config ) {
    my $accepted =
      GPForum::Service::Operations::MetricsTokens->for_config($config)
      ->accepted_metrics_tokens;

    return {
        authorization    => $headers->header('Authorization') || q{},
        configured_token => $accepted->[0],
        accepted_tokens  => $accepted,
        metrics_header   => $headers->header($METRICS_TOKEN_HEADER) || q{},
    };
}

sub request_authorized ( $self, $headers, $config ) {
    return $self->metrics_authorized(
        $self->metrics_input( $headers, $config ) );
}

sub metrics_authorized ( $self, $input ) {
    if ( !$self->access->has_text( $input->{configured_token} ) ) {
        return 1;
    }

    # Any accepted token opens the endpoint, as a bearer token or in the
    # metrics header; with no list of them, the configured token alone.
    my $tokens = $input->{accepted_tokens};
    if ( !$tokens || !@{$tokens} ) {
        $tokens = [ $input->{configured_token} ];
    }
    for my $token ( @{$tokens} ) {
        my $bearer = join q{ }, $BEARER_PREFIX, $token;
        if ( _constant_time_equal( $input->{authorization} || q{}, $bearer ) ) {
            return 1;
        }
        if ( _constant_time_equal( $input->{metrics_header} || q{}, $token ) ) {
            return 1;
        }
    }

    return 0;
}

sub unauthorized_payload {
    return {
        json => {
            error  => $UNAUTHORIZED_ERROR,
            status => $UNAUTHORIZED_STATUS,
        },
        status => $HTTP_UNAUTHORIZED,
    };
}

# Two strings of one length are compared byte by byte to the end, so the time
# taken does not tell how many leading bytes matched.
sub _constant_time_equal ( $candidate, $expected ) {
    if ( !defined $candidate || !defined $expected ) {
        return 0;
    }
    if ( length $candidate != length $expected ) {
        return 0;
    }

    my $diff            = 0;
    my $expected_length = length $expected;
    for my $index ( 0 .. $expected_length - 1 ) {
        my $candidate_byte = ord substr $candidate, $index, 1;
        my $expected_byte  = ord substr $expected,  $index, 1;
        $diff |= $candidate_byte ^ $expected_byte;
    }

    return $diff == 0 ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Web::OperationsAccess - Metrics token HTTP policy.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $ok = $access->metrics_authorized(
        {
            authorization    => $header,
            configured_token => $token,
            metrics_header   => $metrics_header,
        }
    );

    my $full_report =
      $access->request_authorized( $c->req->headers, $c->gp_config );

=head1 DESCRIPTION

Owns C</metrics> token presence, Bearer and C<X-GPForum-Metrics-Token>
comparison, and the unauthorized JSON payload. It does not render HTTP
responses or collect snapshots. L<GPForum::Controller::Operations> and
L<GPForum::Controller::Health> pass it the request headers and render JSON.

The same token, headers and rotation list decide whether C</health> and
C</health/ready> answer their full report or the status alone, so one
operator secret guards every operations body and rotating it changes all of
them at once.

=head1 SUBROUTINES/METHODS

=head2 metrics_token_header

Returns C<X-GPForum-Metrics-Token>.

=head2 metrics_input

Takes a L<Mojo::Headers> and a L<GPForum::Config>. Returns the hash
reference C<metrics_authorized> takes: the C<Authorization> header, the
C<X-GPForum-Metrics-Token> header (each an empty string when absent), and
the tokens accepted now, the one in use first as C<configured_token>. For
the configuration the service started with, those are the ones its
environment file names now (L<GPForum::Service::Operations::MetricsTokens>,
ADR 0124); for any other, the configuration's own.

=head2 request_authorized

Takes a L<Mojo::Headers> and a L<GPForum::Config>. True when
C<metrics_authorized> accepts the request's headers against the config's
tokens.

=head2 metrics_authorized

True when the Bearer or metrics header matches the current token or a
previous token in C<accepted_tokens> in constant time.

It is also true when C<configured_token> is empty, which leaves C</metrics>
and the full C</health> and C</health/ready> reports open. That branch
exists for development and test only: L<GPForum::Config> requires a
non-empty C<GPFORUM_METRICS_TOKEN> in the same environments that require a
rotated session secret (staging and every production profile), so a
deployed application cannot reach this branch.

=head2 unauthorized_payload

Returns the HTTP 401 JSON payload for a missing or invalid metrics token.

=head1 DIAGNOSTICS

None. HTTP rendering stays on the operations controller.

=head1 CONFIGURATION AND ENVIRONMENT

Callers supply the configuration; the tokens come from
L<GPForum::Service::Operations::MetricsTokens>, which follows the
environment file the service started with. L<GPForum::Config> guarantees a
configured token outside development and test, and a file that later names
none leaves the tokens as they were. Production still combines this app-level check with reverse-proxy
allowlists.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>,
L<GPForum::Service::Operations::MetricsTokens> and L<GPForum::Web::Access>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not scrape metrics or enforce network allowlists.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
