# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::HealthPayload;

use strict;
use warnings;
use feature 'signatures';

use Const::Fast;

our $VERSION = '0.001';

const my $HTTP_OK                  => 200;
const my $HTTP_SERVICE_UNAVAILABLE => 503;
const my %STATUS_CODE_FOR => (
    ok       => $HTTP_OK,
    degraded => $HTTP_OK,
    fail     => $HTTP_SERVICE_UNAVAILABLE,
);

sub live ( $, %input ) {
    return {
        status => 'ok',
        check  => 'live',
        time   => $input{clock}->now_iso8601,
    };
}

sub ready_status_code ( $, $status ) {
    return $STATUS_CODE_FOR{$status}
      if exists $STATUS_CODE_FOR{$status};

    return $HTTP_SERVICE_UNAVAILABLE;
}

sub summary ( $, %input ) {
    my $runtime  = $input{runtime};
    my $profile  = $runtime->os_profile;
    my $settings = $runtime->os_feature_settings;

    return {
        status       => 'ok',
        application  => 'GPForum',
        environment  => $input{config}->environment,
        runtime      => $runtime->as_hash,
        os           => $profile->snapshot,
        os_features  => $profile->feature_snapshot($settings),
        os_sockets   => $profile->socket_snapshot($settings),
        os_processes => $profile->process_snapshot($settings),
        time         => $input{clock}->now_iso8601,
    };
}

1;

__END__

=head1 NAME

GPForum::Web::HealthPayload - JSON bodies and status codes for the health endpoints.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $c->render(
        json => GPForum::Web::HealthPayload->live( clock => $clock ) );

    my $readiness = $readiness_check->check;
    $c->render(
        json   => $readiness,
        status => GPForum::Web::HealthPayload->ready_status_code(
            $readiness->{status}
        ),
    );

    $c->render(
        json => GPForum::Web::HealthPayload->summary(
            config  => $config,
            runtime => $runtime,
            clock   => $clock,
        ),
    );

=head1 DESCRIPTION

Builds what L<GPForum::Controller::Health> renders for the live, ready and
summary endpoints, so the controller holds no response shapes. The readiness
status maps to an HTTP code here: C<ok> and C<degraded> answer 200, C<fail>
and any status the map does not know answer 503, so a load balancer takes a
node out only when it cannot serve.

=head1 SUBROUTINES/METHODS

=head2 live

Class method. Takes key/value pairs with C<clock> (an object with
C<now_iso8601>, such as L<GPForum::Service::Clock>). Returns
C<< { status => 'ok', check => 'live', time => ... } >>.

=head2 ready_status_code

Class method. Takes a readiness status string and returns the HTTP status
code to answer with: 200 for C<ok> and C<degraded>, 503 for C<fail> and for
anything else.

=head2 summary

Class method. Takes key/value pairs with C<config> (an object with
C<environment>), C<runtime> (a L<GPForum::Runtime>) and C<clock>. Returns a
hash reference with C<status> (always C<ok>), C<application>
(C<GPForum>), C<environment>, C<runtime> (the runtime's C<as_hash>), C<os>,
C<os_features>, C<os_sockets>, C<os_processes> (the runtime's OS profile
snapshots, the last three built with its C<os_feature_settings>) and
C<time>.

=head1 DIAGNOSTICS

None of its own. C<live> and C<summary> die if a required object is missing
or lacks the method they call.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>.

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
