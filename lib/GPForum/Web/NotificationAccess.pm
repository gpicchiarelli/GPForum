# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::NotificationAccess;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT     => 25;
const my $WRITE_RATE_LIMIT  => 120;
const my $WRITE_RATE_WINDOW => 60;
const my $STATUS_FAILED     => 'failed';
const my $STATUS_NOT_FOUND  => 'not_found';
const my $STATUS_READ       => 'read';
const my $STATUS_ALL_READ   => 'all_read';
const my %WRITE_FLASH => (
    $STATUS_ALL_READ => 'notifications.marked_all_read',
    $STATUS_READ     => 'notifications.marked_read',
);

sub page_limit ( $, $requested ) {
    return $requested || $DEFAULT_LIMIT;
}

sub write_rate_input ( $, $input ) {
    return {
        action         => $input->{action},
        actor_id       => $input->{actor_id},
        limit          => $WRITE_RATE_LIMIT,
        scope          => 'notification_http',
        window_seconds => $WRITE_RATE_WINDOW,
    };
}

sub is_failed ( $self, $result ) {
    return $self->_status($result) eq $STATUS_FAILED ? 1 : 0;
}

sub failure_status ( $self, $result ) {
    my $status = $self->_status($result);
    if ( $status eq $STATUS_NOT_FOUND ) {
        return $status;
    }

    my $undefined;
    return $undefined;
}

sub marked_read_status {
    return $STATUS_READ;
}

sub marked_all_read_status {
    return $STATUS_ALL_READ;
}

sub write_flash_key ( $, $status ) {
    my $undefined;

    if ( !defined $status ) {
        return $undefined;
    }
    if ( exists $WRITE_FLASH{$status} ) {
        return $WRITE_FLASH{$status};
    }

    return $undefined;
}

sub _status ( $, $result ) {
    return $result->{status} || q{};
}

1;

__END__

=head1 NAME

GPForum::Web::NotificationAccess - Notification page limits and HTTP policy.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $limit = $access->page_limit($requested);

=head1 DESCRIPTION

Owns inbox/mention page limits, the C<notification_http> write rate-limit
hash, and workflow failure-status mapping. It does not render HTTP responses
or load inbox rows. L<GPForum::Controller::Notifications::Base> still checks
CSRF, sessions, and Guard errors.

=head1 SUBROUTINES/METHODS

=head2 page_limit

Returns a requested page size or the default of 25.

=head2 write_rate_input

Returns the C<notification_http> rate-limit arguments.

=head2 is_failed

True when the workflow status is C<failed>.

=head2 failure_status

Returns C<not_found> when that status is present.

=head2 marked_read_status

Returns C<read>.

=head2 marked_all_read_status

Returns C<all_read>.

=head2 write_flash_key

Returns the i18n catalog key for a successful HTML write, or undef when the
status has no flash copy.

=head1 DIAGNOSTICS

None. HTTP rendering stays on the notification controllers.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

CSRF, authentication, telemetry, and Guard rendering remain on
L<GPForum::Controller::Notifications::Base>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
