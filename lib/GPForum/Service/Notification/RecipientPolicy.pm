# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Notification::RecipientPolicy;

use strict;
use warnings;

use Mojo::Base 'GPForum::Service::Forum::Readability', -signatures;

our $VERSION = '0.001';

# ADR 0102: a notification about a post or thread reaches only a recipient
# who can read it. A reply in a private thread, or a mention in a
# members-only category, used to notify everyone subscribed or mentioned and
# hand them the thread, the post and the actor. A public source costs one
# query; any other, the recipient's viewer as well.
sub can_notify ( $self, $recipient, $source_type, $source_id, @ ) {    ## no critic (Subroutines::ProhibitManyArgs)
    return $self->readable_by( $recipient, $source_type, $source_id );
}

1;

__END__

=head1 NAME

GPForum::Service::Notification::RecipientPolicy - Who may be notified about a source.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $dispatcher = GPForum::Service::Notification::Dispatcher->new(
        permission_engine =>
          GPForum::Service::Notification::RecipientPolicy->new(
            schema => $schema ),
        ...
    );

=head1 DESCRIPTION

The notification dispatcher's permission hook (ADR 0102): a recipient is
notified about a post or thread only if they can read it, as
L<GPForum::Service::Forum::Readability> judges.

=head1 SUBROUTINES/METHODS

=head2 can_notify

True when the recipient may be notified about the source.

=head1 DIAGNOSTICS

Dies when the database does; the dispatcher then fails the notification.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Forum::Readability>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known. Notifications already in an inbox are re-checked when the inbox
is read (the dispatcher's C<readability>).

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
