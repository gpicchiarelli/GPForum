package GPForum::Web::AdminAccess;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT               => 50;
const my $DASHBOARD_LIMIT             => 10;
const my $WRITE_RATE_LIMIT            => 20;
const my $WRITE_RATE_WINDOW           => 60;
const my $WRITE_ACTION                => 'admin.write';
const my $ADMIN_RESOURCE              => 'admin_console';
const my $ACTION_MANAGE               => 'manage';
const my $ACTION_VIEW                 => 'view';
const my $DEFAULT_REDIRECT            => 'admin_roles';
const my $STATUS_FAILED               => 'failed';
const my $STATUS_NOT_FOUND            => 'not_found';
const my $STATUS_INVALID              => 'invalid';
const my $STATUS_ROLE_CREATED         => 'role_created';
const my $STATUS_PERMISSION_CREATED   => 'permission_created';
const my $STATUS_ROLE_PERM_ATTACHED   => 'role_permission_attached';
const my $STATUS_ROLE_BOUND           => 'role_bound';
const my $STATUS_ROLE_BINDING_REVOKED => 'role_binding_revoked';
const my $STATUS_CATEGORY_CREATED     => 'category_created';
const my $STATUS_CATEGORY_UPDATED     => 'category_updated';
const my $CATEGORIES_REDIRECT         => 'admin_categories';

sub page_limit {
    my ( undef, $requested ) = @_;

    return $requested || $DEFAULT_LIMIT;
}

sub dashboard_limit {
    return $DASHBOARD_LIMIT;
}

sub write_action {
    return $WRITE_ACTION;
}

sub write_rate_input {
    my ( undef, $input ) = @_;

    return {
        action         => $input->{action},
        actor_id       => $input->{actor_id},
        limit          => $WRITE_RATE_LIMIT,
        scope          => 'admin_http',
        window_seconds => $WRITE_RATE_WINDOW,
    };
}

sub manage_action {
    return $ACTION_MANAGE;
}

sub view_action {
    return $ACTION_VIEW;
}

sub role_created_status {
    return $STATUS_ROLE_CREATED;
}

sub permission_created_status {
    return $STATUS_PERMISSION_CREATED;
}

sub role_permission_attached_status {
    return $STATUS_ROLE_PERM_ATTACHED;
}

sub role_bound_status {
    return $STATUS_ROLE_BOUND;
}

sub role_binding_revoked_status {
    return $STATUS_ROLE_BINDING_REVOKED;
}

sub category_created_status {
    return $STATUS_CATEGORY_CREATED;
}

sub category_updated_status {
    return $STATUS_CATEGORY_UPDATED;
}

sub categories_redirect {
    return $CATEGORIES_REDIRECT;
}

sub permission_target {
    my ( undef, $action ) = @_;

    return {
        action        => $action,
        resource_type => $ADMIN_RESOURCE,
    };
}

sub default_redirect {
    return $DEFAULT_REDIRECT;
}

sub is_failed {
    my ( $self, $result ) = @_;

    return $self->_status($result) eq $STATUS_FAILED ? 1 : 0;
}

sub failure_status {
    my ( $self, $result ) = @_;

    my $status = $self->_status($result);
    if ( $status eq $STATUS_NOT_FOUND ) {
        return $status;
    }
    if ( $status eq $STATUS_INVALID ) {
        return $status;
    }

    return;
}

sub invalid_request {
    my ( undef, $errors ) = @_;

    return {
        error  => 'The submitted admin request was invalid.',
        errors => $errors,
        title  => 'Invalid admin request',
    };
}

sub _status {
    my ( undef, $result ) = @_;

    return $result->{status} || q{};
}

1;

__END__

=head1 NAME

GPForum::Web::AdminAccess - Admin page limits and HTTP policy.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $limit = $access->page_limit($requested);

=head1 DESCRIPTION

Owns admin catalog page limits, the dashboard row cap, the
C<admin_http> write rate-limit hash, the C<admin_console>/C<manage>
permission hash, the catalog C<view> action, catalog, binding, and
category write-success statuses, workflow failure-status mapping,
Guard payloads for invalid admin commands, and the default roles redirect.
It does not render HTTP responses or load roles.
L<GPForum::Controller::Admin::Base> still checks CSRF, sessions,
permissions, the rate limiter, telemetry, and Guard errors.

=head1 SUBROUTINES/METHODS

=head2 write_action

Returns C<admin.write>.

=head2 write_rate_input

Returns the C<admin_http> rate-limit arguments.

=head2 page_limit

Returns a requested page size or the default of 50.

=head2 dashboard_limit

Returns the dashboard summary/audit/role row cap of 10.

=head2 manage_action

Returns the admin-console permission action.

=head2 view_action

Returns the catalog review permission action.

=head2 role_created_status

Returns C<role_created>.

=head2 permission_created_status

Returns C<permission_created>.

=head2 role_permission_attached_status

Returns C<role_permission_attached>.

=head2 role_bound_status

Returns C<role_bound>.

=head2 role_binding_revoked_status

Returns C<role_binding_revoked>.

=head2 category_created_status

Returns C<category_created>.

=head2 category_updated_status

Returns C<category_updated>.

=head2 categories_redirect

Returns the categories catalog route name.

=head2 permission_target

Returns the C<admin_console> permission hash for an action.

=head2 default_redirect

Returns the roles catalog route name.

=head2 is_failed

True when the workflow status is C<failed>.

=head2 failure_status

Returns C<not_found> or C<invalid> when those statuses are present.

=head2 invalid_request

Returns the Guard bad-request payload for an invalid admin command.

=head1 DIAGNOSTICS

None. HTTP rendering stays on the admin controllers.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

CSRF, authentication, permission checks, rate-limiter calls, telemetry,
and Guard rendering remain on L<GPForum::Controller::Admin::Base>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
