# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Privacy::Erasure;

use strict;
use warnings;

use Const::Fast;
use GPForum::Service::Privacy::Record;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $USER_AGGREGATE   => 'user';
const my $DISPLAY_DELETED  => 'Deleted member';
const my $ERASED_PASSWORD  => 'erased';
const my $DELETED_STATUS   => 'deleted';
const my $ANON_LOCAL_PART  => 'deleted+';
const my $ANON_DOMAIN      => 'example.invalid';
const my $ANON_NAME_PREFIX => 'deleted-';

has record => sub { return GPForum::Service::Privacy::Record->new; };

sub is_user_resource ( $self, $request ) {
    my $type = $self->record->column( $request, 'resource_type' ) || q{};
    return $type eq $USER_AGGREGATE ? 1 : 0;
}

sub skip_reason ( $self, $request, $user ) {
    if ( !$self->is_user_resource($request) ) {
        return 'resource_not_user';
    }
    if ( !$user ) {
        return 'user_not_found';
    }

    my $undefined;
    return $undefined;
}

sub already_deleted ( $self, $user ) {
    return defined $self->record->column( $user, 'deleted_at' ) ? 1 : 0;
}

sub anonymous_username ( $self, $user_id ) {
    return $ANON_NAME_PREFIX . $self->safe_identifier($user_id);
}

sub anonymous_email ( $self, $user_id ) {
    return join q{@}, $ANON_LOCAL_PART . $self->safe_identifier($user_id),
      $ANON_DOMAIN;
}

sub safe_identifier ( $, $value ) {
    $value =~ s/[^[:alnum:]]//gmsx;

    return lc $value;
}

sub user_values ( $self, $user_id, $timestamp ) {
    return {
        deleted_at        => $timestamp,
        display_name      => $DISPLAY_DELETED,
        email_normalized  => $self->anonymous_email($user_id),
        email_verified_at => undef,
        password_hash     => $ERASED_PASSWORD,
        status            => $DELETED_STATUS,
        trust_level       => 0,
        updated_at        => $timestamp,
        username          => $self->anonymous_username($user_id),
    };
}

sub result ( $, $user_id, $already_deleted ) {
    return {
        idempotent => $already_deleted ? 1 : 0,
        user_id    => $user_id,
    };
}

1;

__END__

=head1 NAME

GPForum::Service::Privacy::Erasure - User erasure identity values.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $values = $erasure->user_values( $user_id, $timestamp );

=head1 DESCRIPTION

Owns user-resource checks and the anonymized username, email, and status
values written during erasure. It does not load users or revoke credentials.
L<GPForum::Service::Privacy::DeletionWorkflow> keeps those writes inside the
service transaction.

=head1 SUBROUTINES/METHODS

=head2 is_user_resource

True when the deletion request targets a user aggregate.

=head2 skip_reason

Returns C<resource_not_user> or C<user_not_found> when erasure cannot run.

=head2 already_deleted

True when the user row already has C<deleted_at>.

=head2 anonymous_username

Returns the deleted-username for a user id.

=head2 anonymous_email

Returns the deleted invalid-mail address for a user id.

=head2 safe_identifier

Keeps lowercase alphanumeric characters from a user id.

=head2 user_values

Returns the user-row update hash for first-time erasure.

=head2 result

Returns the anonymize result including idempotent replay.

=head1 DIAGNOSTICS

Skip reasons are plain strings consumed by the deletion workflow.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<GPForum::Service::Privacy::Record>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Credential and session revocation stay in the workflow because they need
resultsets.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
