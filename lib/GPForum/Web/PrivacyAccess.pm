# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::PrivacyAccess;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT             => 25;
const my $WRITE_RATE_LIMIT          => 20;
const my $REQUEST_RATE_LIMIT        => 5;
const my $WRITE_RATE_WINDOW         => 60;
const my $WRITE_ACTION              => 'privacy.write';
const my $REQUEST_ACTION            => 'privacy.request';
const my $REVIEW_ACTION             => 'privacy.review';
const my $PRIVACY_RESOURCE          => 'privacy_rights';
const my $ACTION_MANAGE             => 'manage';
const my $ACTION_VIEW               => 'view';
const my $STATUS_DELETION_APPROVED  => 'deletion_approved';
const my $STATUS_DELETION_HELD      => 'deletion_held';
const my $STATUS_DELETION_REQUESTED => 'deletion_requested';
const my $STATUS_ERASURE_COMPLETED  => 'erasure_completed';
const my $STATUS_EXPORT_REQUESTED   => 'export_requested';
const my $DEFAULT_REDIRECT          => 'privacy_dashboard';
const my $STATUS_FAILED             => 'failed';
const my $STATUS_NOT_FOUND          => 'not_found';
const my $STATUS_INVALID            => 'invalid';
const my $STATUS_CONFLICT           => 'conflict';
const my $CONFLICT_STATUS           => 'blocked';
const my %WRITE_FLASH => (
    $STATUS_DELETION_APPROVED  => 'privacy.deletion_approved',
    $STATUS_DELETION_HELD      => 'privacy.deletion_held',
    $STATUS_DELETION_REQUESTED => 'privacy.deletion_requested',
    $STATUS_ERASURE_COMPLETED  => 'privacy.erasure_completed',
    $STATUS_EXPORT_REQUESTED   => 'privacy.export_requested',
);

sub page_limit ( $, $requested ) {
    return $requested || $DEFAULT_LIMIT;
}

sub write_action {
    return $WRITE_ACTION;
}

sub request_action {
    return $REQUEST_ACTION;
}

sub review_action {
    return $REVIEW_ACTION;
}

sub write_limit_for ( $, $action ) {
    if ( $action eq $REQUEST_ACTION ) {
        return $REQUEST_RATE_LIMIT;
    }

    return $WRITE_RATE_LIMIT;
}

sub write_rate_input ( $self, $input ) {
    return {
        action         => $input->{action},
        actor_id       => $input->{actor_id},
        limit          => $self->write_limit_for( $input->{action} ),
        scope          => 'privacy_http',
        window_seconds => $WRITE_RATE_WINDOW,
    };
}

sub manage_action {
    return $ACTION_MANAGE;
}

sub view_action {
    return $ACTION_VIEW;
}

sub deletion_approved_status {
    return $STATUS_DELETION_APPROVED;
}

sub deletion_held_status {
    return $STATUS_DELETION_HELD;
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

sub export_download_filename ( $, $export_request_id ) {
    my $id = $export_request_id || 'bundle';
    $id =~ s/[^[:alnum:]._-]+/_/gmsx;

    return 'gpforum-export-' . $id . '.json';
}

sub export_download_disposition ( $self, $export_request_id ) {
    return
      'attachment; filename="'
      . $self->export_download_filename($export_request_id) . q{"};
}

sub permission_target ( $, $action ) {
    return {
        action        => $action,
        resource_type => $PRIVACY_RESOURCE,
    };
}

sub default_redirect {
    return $DEFAULT_REDIRECT;
}

sub is_failed ( $self, $result ) {
    return $self->_status($result) eq $STATUS_FAILED ? 1 : 0;
}

sub failure_status ( $self, $result ) {
    my $status = $self->_status($result);
    if ( $status eq $STATUS_NOT_FOUND ) {
        return $status;
    }
    if ( $status eq $STATUS_INVALID ) {
        return $status;
    }
    if ( $status eq $STATUS_CONFLICT ) {
        return $status;
    }

    my $undefined;
    return $undefined;
}

sub invalid_request ( $, $errors ) {
    return {
        error  => 'The submitted privacy request was invalid.',
        errors => $errors,
        title  => 'Invalid privacy request',
    };
}

sub conflict_payload ( $, $error ) {
    return {
        error  => $error,
        status => $CONFLICT_STATUS,
        title  => 'Privacy action blocked',
    };
}

sub _status ( $, $result ) {
    return $result->{status} || q{};
}

1;

__END__

=head1 NAME

GPForum::Web::PrivacyAccess - Privacy page limits and HTTP policy.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $limit = $access->page_limit($requested);

=head1 DESCRIPTION

Owns privacy list page limits, the C<privacy_http> write rate-limit hash
with a tighter member-request cap,
the C<privacy_rights>/C<manage> permission hash, the catalog C<view>
action, review write-success statuses, workflow failure-status mapping
including C<conflict>, Guard payloads for invalid and blocked actions, and
the default dashboard redirect. It does not render HTTP responses or load
deletion requests. L<GPForum::Controller::Privacy::Base> still checks CSRF,
sessions, permissions, the rate limiter, and Guard errors.

=head1 SUBROUTINES/METHODS

=head2 write_action

Returns C<privacy.write>.

=head2 request_action

Returns C<privacy.request>.

=head2 review_action

Returns C<privacy.review>.

=head2 write_limit_for

Returns 5 for member export/deletion requests, otherwise 20.

=head2 write_rate_input

Returns the C<privacy_http> rate-limit arguments.

=head2 page_limit

Returns a requested page size or the default of 25.

=head2 manage_action

Returns the staff-review permission action.

=head2 view_action

Returns the privacy-review permission action.

=head2 deletion_approved_status

Returns C<deletion_approved>.

=head2 deletion_held_status

Returns C<deletion_held>.

=head2 write_flash_key

Returns the i18n catalog key for a successful HTML write, or undef when the
status has no flash copy.

=head2 export_download_filename

Returns a safe JSON attachment filename for a completed export.

=head2 export_download_disposition

Returns the Content-Disposition header value for that download.

=head2 permission_target

Returns the C<privacy_rights> permission hash for an action.

=head2 default_redirect

Returns the member dashboard route name.

=head2 is_failed

True when the workflow status is C<failed>.

=head2 failure_status

Returns C<not_found>, C<invalid>, or C<conflict> when those statuses are
present.

=head2 invalid_request

Returns the Guard bad-request payload for an invalid privacy command.

=head2 conflict_payload

Returns the Guard conflict payload for a blocked privacy action.

=head1 DIAGNOSTICS

None. HTTP rendering stays on the privacy controllers.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

CSRF, authentication, permission checks, rate-limiter calls, telemetry,
and Guard rendering remain on L<GPForum::Controller::Privacy::Base>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
