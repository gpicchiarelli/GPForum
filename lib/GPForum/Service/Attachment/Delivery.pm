# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::Delivery;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

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
    my $undefined;
    ## no critic (BuiltinFunctions::ProhibitUniversalCan)
    # Deliberate: the point is to bypass an overridden can(). The search
    # permission engine defines its own can($actor, $action, ...), and
    # $object->can('method') called that instead of asking about methods.
    return $undefined if !UNIVERSAL::can( $storage, 'path_for' );
    ## use critic

    return $storage->path_for($object_key);
}

1;
