# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::OperationsAccess;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

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

sub metrics_authorized ( $self, $input ) {
    if ( !$self->access->has_text( $input->{configured_token} ) ) {
        return 1;
    }

    return $self->_accepted_token_matches($input);
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

sub _accepted_token_matches ( $self, $input ) {
    for my $token ( @{ $self->_accepted_tokens($input) } ) {
        if ( $self->_token_matches_value( $input, $token ) ) {
            return 1;
        }
    }

    return 0;
}

sub _accepted_tokens ( $, $input ) {
    my $tokens = $input->{accepted_tokens};
    if ( $tokens && @{$tokens} ) {
        return $tokens;
    }

    return [ $input->{configured_token} ];
}

sub _token_matches_value ( $self, $input, $token ) {
    return $self->_token_matches(
        {
            authorization    => $input->{authorization},
            configured_token => $token,
            metrics_header   => $input->{metrics_header},
        }
    );
}

sub _token_matches ( $self, $input ) {
    if ( $self->_bearer_ok($input) ) {
        return 1;
    }

    return $self->_header_ok($input);
}

sub _bearer_ok ( $self, $input ) {
    return $self->_constant_time_equal( $input->{authorization} || q{},
        $self->_bearer_expected( $input->{configured_token} ) );
}

sub _header_ok ( $self, $input ) {
    return $self->_constant_time_equal( $input->{metrics_header} || q{},
        $input->{configured_token} );
}

sub _bearer_expected ( $, $token ) {
    return join q{ }, $BEARER_PREFIX, $token;
}

sub _constant_time_equal ( $self, $candidate, $expected ) {
    if ( !$self->_same_length_defined( $candidate, $expected ) ) {
        return 0;
    }

    return $self->_constant_time_diff( $candidate, $expected ) == 0 ? 1 : 0;
}

sub _same_length_defined ( $, $candidate, $expected ) {
    if ( !defined $candidate || !defined $expected ) {
        return 0;
    }

    return length $candidate == length $expected ? 1 : 0;
}

sub _constant_time_diff ( $, $candidate, $expected ) {
    my $expected_length = length $expected;
    my $diff            = 0;
    for my $index ( 0 .. $expected_length - 1 ) {
        my $candidate_byte = ord substr $candidate, $index, 1;
        my $expected_byte  = ord substr $expected,  $index, 1;
        $diff |= $candidate_byte ^ $expected_byte;
    }

    return $diff;
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

=head1 DESCRIPTION

Owns C</metrics> token presence, Bearer and C<X-GPForum-Metrics-Token>
comparison, and the unauthorized JSON payload. It does not render HTTP
responses or collect snapshots. L<GPForum::Controller::Operations> still
reads request headers and renders JSON.

=head1 SUBROUTINES/METHODS

=head2 metrics_token_header

Returns C<X-GPForum-Metrics-Token>.

=head2 metrics_authorized

True when the Bearer or metrics header matches the current token or a
previous token in C<accepted_tokens> in constant time.

It is also true when C<configured_token> is empty, which leaves C</metrics>
open. That branch exists for development and test only: L<GPForum::Config>
requires a non-empty C<GPFORUM_METRICS_TOKEN> in the same environments that
require a rotated session secret (staging and every production profile), so
a deployed application cannot reach this branch.

=head2 unauthorized_payload

Returns the HTTP 401 JSON payload for a missing or invalid metrics token.

=head1 DIAGNOSTICS

None. HTTP rendering stays on the operations controller.

=head1 CONFIGURATION AND ENVIRONMENT

Callers supply the configured metrics token and optional previous tokens.
L<GPForum::Config> guarantees a configured token outside development and
test. Production still combines this app-level check with reverse-proxy
allowlists.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>, and L<GPForum::Web::Access>.

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
