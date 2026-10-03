# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::AdminAccess;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

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
const my $STATUS_CONFLICT             => 'conflict';
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
const my $STATUS_DEAD_LETTER_REPLAYED => 'dead_letter_replayed';
const my $STATUS_SEARCH_REBUILD       => 'search_rebuild_requested';
const my $STATUS_CACHE_PURGED         => 'cache_purged';
const my $STATUS_CACHE_PURGED_LOCALLY => 'cache_purged_locally';
const my $JOBS_REDIRECT               => 'admin_jobs';
const my $STATUS_MAIL_TEST_SENT       => 'mail_test_sent';
const my $STATUS_MAIL_TEST_FAILED     => 'mail_test_failed';
const my $STATUS_ANTIVIRUS_PASSED     => 'antivirus_check_passed';
const my $STATUS_ANTIVIRUS_PROBLEM    => 'antivirus_check_problem';
const my $STATUS_ANTIVIRUS_DISABLED   => 'antivirus_check_disabled';
const my $SETTINGS_REDIRECT           => 'admin_settings';

const my %WRITE_FLASH => (
    $STATUS_ANTIVIRUS_DISABLED   => 'admin.antivirus_check_disabled',
    $STATUS_ANTIVIRUS_PASSED     => 'admin.antivirus_check_passed',
    $STATUS_ANTIVIRUS_PROBLEM    => 'admin.antivirus_check_problem',
    $STATUS_CACHE_PURGED         => 'admin.cache_purged',
    $STATUS_CACHE_PURGED_LOCALLY => 'admin.cache_purged_locally',
    $STATUS_CATEGORY_CREATED     => 'admin.category_created',
    $STATUS_CATEGORY_UPDATED     => 'admin.category_updated',
    $STATUS_DEAD_LETTER_REPLAYED => 'admin.dead_letter_replayed',
    $STATUS_MAIL_TEST_FAILED     => 'admin.mail_test_failed',
    $STATUS_MAIL_TEST_SENT       => 'admin.mail_test_sent',
    $STATUS_PERMISSION_CREATED   => 'admin.permission_created',
    $STATUS_ROLE_BOUND           => 'admin.role_bound',
    $STATUS_ROLE_BINDING_REVOKED => 'admin.role_binding_revoked',
    $STATUS_ROLE_CREATED         => 'admin.role_created',
    $STATUS_ROLE_PERM_ATTACHED   => 'admin.role_permission_attached',
    $STATUS_SEARCH_REBUILD       => 'admin.search_rebuild_requested',
);

# A diagnostic that ran but did not pass is not a success: its flash says so
# as a warning, and scanning that is off as a notice. So is a purge that left
# the shared cache's copies in place.
const my %WRITE_FLASH_TYPE => (
    $STATUS_ANTIVIRUS_DISABLED   => 'notice',
    $STATUS_ANTIVIRUS_PROBLEM    => 'warning',
    $STATUS_CACHE_PURGED_LOCALLY => 'warning',
    $STATUS_MAIL_TEST_FAILED     => 'warning',
);

sub page_limit ( $, $requested ) {
    return $requested || $DEFAULT_LIMIT;
}

sub dashboard_limit {
    return $DASHBOARD_LIMIT;
}

sub write_action {
    return $WRITE_ACTION;
}

sub write_rate_input ( $, $input ) {
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

sub dead_letter_replayed_status {
    return $STATUS_DEAD_LETTER_REPLAYED;
}

sub search_rebuild_status {
    return $STATUS_SEARCH_REBUILD;
}

# The answer to a purge: purged only when it reached the shared cache too
# (Admin::Maintenance's "purged"). Otherwise every process's own copy is gone
# and GlifiStore's stay until their TTL, which the console must not call
# purged: an operator who purged to take a page down would believe it down.
sub cache_purge_status ( $, $purge_status ) {
    return ( ( $purge_status // q{} ) eq 'purged' )
      ? $STATUS_CACHE_PURGED
      : $STATUS_CACHE_PURGED_LOCALLY;
}

# What a maintenance flash interpolates: the tags a purge did not reach in
# the shared cache, as one comma-separated list (empty for anything else).
sub maintenance_flash_variables ( $, $stored ) {
    my $unreached = ref $stored eq 'HASH' ? $stored->{unreached_tags} : undef;
    my @tags      = ref $unreached eq 'ARRAY' ? @{$unreached}         : ();

    return { tags => join q{, }, @tags };
}

sub jobs_redirect {
    return $JOBS_REDIRECT;
}

sub settings_redirect {
    return $SETTINGS_REDIRECT;
}

# The answer to a test message: sent, or failed with the transport's error.
sub mail_test_status ( $, $outcome ) {
    return ( ( $outcome // q{} ) eq 'sent' )
      ? $STATUS_MAIL_TEST_SENT
      : $STATUS_MAIL_TEST_FAILED;
}

# The answer to an antivirus check: passed only when it is ok, off when
# scanning is disabled, and a problem otherwise -- degraded signatures, a
# failed scan, or a scanner the console cannot run.
sub antivirus_check_status ( $, $report_status ) {
    my $status = $report_status // q{};
    return $STATUS_ANTIVIRUS_PASSED   if $status eq 'ok';
    return $STATUS_ANTIVIRUS_DISABLED if $status eq 'disabled';

    return $STATUS_ANTIVIRUS_PROBLEM;
}

sub categories_redirect {
    return $CATEGORIES_REDIRECT;
}

sub permission_target ( $, $action ) {
    return {
        action        => $action,
        resource_type => $ADMIN_RESOURCE,
    };
}

sub default_redirect {
    return $DEFAULT_REDIRECT;
}

sub write_flash_key ( $, $status ) {
    if ( !defined $status ) {
        return undef;
    }
    if ( exists $WRITE_FLASH{$status} ) {
        return $WRITE_FLASH{$status};
    }

    return undef;
}

sub write_flash_type ( $, $status ) {
    my $key = $status // q{};

    return exists $WRITE_FLASH_TYPE{$key} ? $WRITE_FLASH_TYPE{$key} : 'success';
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

    return undef;
}

sub invalid_request ( $, $errors ) {
    return {
        error  => 'The submitted admin request was invalid.',
        errors => $errors,
        title  => 'Invalid admin request',
    };
}

sub _status ( $, $result ) {
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

=head2 search_rebuild_status

Returns C<search_rebuild_requested>.

=head2 cache_purge_status

Takes the status of L<GPForum::Service::Admin::Maintenance/purge_public_cache>.
Returns C<cache_purged> for C<purged>, and C<cache_purged_locally> for
anything else (C<purged_locally>: the shared cache was not reached for one
of the tags).

=head2 maintenance_flash_variables

Takes a maintenance command's stored result. Returns the variables its flash
interpolates: C<tags>, the result's C<unreached_tags> joined with commas, or
the empty string when it has none.

=head2 dead_letter_replayed_status

Returns C<dead_letter_replayed>.

=head2 jobs_redirect

The async jobs page, where a replay returns to.

=head2 settings_redirect

The settings page, where a test message and an antivirus check return to.

=head2 mail_test_status

C<mail_test_sent> for a sent test message, C<mail_test_failed> otherwise.

=head2 antivirus_check_status

C<antivirus_check_passed>, C<antivirus_check_disabled> or
C<antivirus_check_problem> for an antivirus report's status.

=head2 categories_redirect

Returns the categories catalog route name.

=head2 permission_target

Returns the C<admin_console> permission hash for an action.

=head2 default_redirect

Returns the roles catalog route name.

=head2 write_flash_key

Returns the i18n catalog key for a successful HTML write, or undef when the
status has no flash copy.

=head2 write_flash_type

The flash type for a write status: C<success>, or C<warning> and C<notice>
for a diagnostic that did not pass or had nothing to check, and C<warning>
for a purge that did not reach the shared cache.

=head2 is_failed

True when the workflow status is C<failed>.

=head2 failure_status

Returns C<not_found>, C<invalid>, or C<conflict> when those statuses are
present.

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
