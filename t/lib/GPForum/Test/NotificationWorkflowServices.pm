# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::NotificationWorkflowServices;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

has preference_updates => sub { return []; };

sub mark_read {
    my ( undef, $notification_id, $user_id ) = @_;

    if ( $notification_id eq 'boom' ) {
        croak 'dispatcher down';
    }
    if ( $notification_id eq 'gone' ) {
        return;
    }
    if ( $notification_id eq 'missing' ) {
        return { error => 'not_found', ok => 0 };
    }

    return {
        notification_id   => $notification_id,
        ok                => 1,
        recipient_user_id => $user_id,
    };
}

sub mark_all_read {
    my ( undef, $user_id ) = @_;

    if ( $user_id eq 'boom' ) {
        croak 'dispatcher down';
    }

    return {
        duplicate         => 0,
        marked_count      => 2,
        ok                => 1,
        recipient_user_id => $user_id,
        unread_count      => 0,
    };
}

sub set_preferences {
    my ( $self, $input ) = @_;

    if ( _preference_user($input) eq 'boom' ) {
        croak 'preference store down';
    }

    return $self->_recorded_preferences($input);
}

sub _recorded_preferences {
    my ( $self, $input ) = @_;

    if ( _preference_user($input) eq 'gone' ) {
        return;
    }

    push @{ $self->preference_updates }, $input;

    return $input->{preferences} || [];
}

sub _preference_user {
    my ($input) = @_;

    return $input->{user_id} || q{};
}

1;

__END__

=head1 NAME

GPForum::Test::NotificationWorkflowServices - Notification write fakes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $services = GPForum::Test::NotificationWorkflowServices->new;

=head1 DESCRIPTION

Test double for C<Notification::Workflow> mark-read and preference outcomes:
success, missing row, empty result, and store exceptions.

=head1 SUBROUTINES/METHODS

=head2 mark_read

Returns a dispatcher-shaped hash, an empty result, or throws.

=head2 mark_all_read

Marks the inbox read or throws for C<boom>.

=head2 set_preferences

Records preference writes or throws.

=head1 DIAGNOSTICS

The C<boom> notification id or user id throws.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Intended only for workflow unit tests.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
