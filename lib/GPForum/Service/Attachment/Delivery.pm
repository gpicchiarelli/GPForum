# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::Delivery;

use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Service::Attachment::Store;

our $VERSION = '0.001';

has storage => undef;
has store   => sub { return GPForum::Service::Attachment::Store->new; };

# Authorized downloads used to come back with the whole object in a scalar,
# which the controller then handed to render(). A 20 MB attachment (the limit
# nginx enforces) was pinned in a worker for the life of the request, once in
# the scalar and again in the response buffer. Concurrency multiplied it.
#
# A backend that can name a path returns the path and nothing else: the caller
# streams it. Only a backend that cannot is read into memory, and none of the
# shipped ones take that branch.
sub download ( $self, $input ) {
    my $decision = $self->store->download_for($input);
    return $decision if !$decision->{ok};

    return { %{$decision}, %{ $self->_body( $decision->{object_key} ) } };
}

sub _body ( $self, $object_key ) {
    my $path = $self->_object_path($object_key);
    return { object_path => $path } if defined $path;

    return { content => $self->storage->read_object($object_key) };
}

# UNIVERSAL::can by name, not $storage->can(...): a storage double is free to
# define its own can(), and the search permission engine already proved that
# hazard is not theoretical here.
sub _object_path ( $self, $object_key ) {
    my $storage = $self->storage;
    ## no critic (BuiltinFunctions::ProhibitUniversalCan)
    # Deliberate: the point is to bypass an overridden can(). The search
    # permission engine defines its own can($actor, $action, ...), and
    # $object->can('method') called that instead of asking about methods.
    return undef if !UNIVERSAL::can( $storage, 'path_for' );
    ## use critic

    return $storage->path_for($object_key);
}

1;

__END__

=head1 NAME

GPForum::Service::Attachment::Delivery - Authorize an attachment download and hand back a path to stream.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $delivery = GPForum::Service::Attachment::Delivery->new(
        storage => GPForum::Service::Attachment::FilesystemStorage->new,
        store   => $attachment_store,
    );

    my $download = $delivery->download(
        {
            attachment_id  => $attachment_id,
            viewer         => $viewer,
            viewer_user_id => $user_id,
        }
    );
    # $download->{object_path} to stream, or $download->{error} when !ok

=head1 DESCRIPTION

Authorized downloads used to come back with the whole object in a scalar,
which kept a 20 MB attachment in a worker for the whole request, once in the
scalar and again in the response buffer. Now the access decision comes from
L<GPForum::Service::Attachment::Store> and, when it allows the download, the
storage backend is asked for a path that the caller streams. Only a backend
without C<path_for> has its object read into memory, and none of the shipped
backends takes that branch.

The C<path_for> check uses C<UNIVERSAL::can> by name rather than
C<< $storage->can >>, so a storage double that defines its own C<can> is not
asked the wrong question.

=head1 SUBROUTINES/METHODS

=head2 download

Takes the hash reference that
L<GPForum::Service::Attachment::Store/download_for> takes (C<attachment_id>,
C<viewer>, C<viewer_user_id>). When the store refuses, returns its decision
unchanged (C<< ok => 0 >> with C<error> set to C<not_found> or
C<forbidden>). When it allows, returns the decision with C<object_path> added
when the storage can name a path, or C<content> (the object's bytes)
otherwise.

=head1 DIAGNOSTICS

Refusals are returned, not thrown. Errors from the store or from the
storage's C<path_for> or C<read_object> propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Attachment::Store>.

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
