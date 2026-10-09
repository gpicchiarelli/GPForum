# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::X;

use Carp qw(croak);
use Mojo::Base -base, -signatures;
use v5.40;
use overload
  q{""}    => \&_stringified,
  bool     => \&_true,
  fallback => 1;

our $VERSION = '0.001';

# What went wrong, in the words every existing reader of the error already
# matches: an exception stringifies to its message and nothing else.
has 'message';

# The error this one stands for, when it wraps one: the DBI exception behind a
# conflict, say.
has 'cause';

# How the outbox treats a delivery that died with this exception
# (Outbox::FailureType reads a declared failure_type before any regex).
has failure_type => 'transient';

# Where it was thrown, "FILE line N". Kept out of the string, so a message
# shown to an operator or matched by a test does not change with the line.
has 'location';

sub new ( $class, @arguments ) {
    my $self    = $class->SUPER::new(@arguments);
    my $message = $self->message;
    if ( !defined $message || !length "$message" ) {
        require GPForum::X::Argument;
        GPForum::X::Argument->new( message => "$class requires message" )
          ->throw;
    }

    return $self;
}

sub throw ( $invocant, @arguments ) {
    my $error = ref $invocant ? $invocant : $invocant->new(@arguments);
    if ( !defined $error->location ) {
        my ( undef, $file, $line ) = caller;
        $error->location("$file line $line");
    }

    croak $error;
}

sub rethrow ($self) {
    croak $self;
}

sub caught ( $class, $error ) {
    if ( blessed $error && $error->isa($class) ) {
        return $error;
    }

    return undef;
}

sub TO_JSON ($self) {
    return $self->_stringified;
}

sub _stringified ( $self, @ ) {
    return q{} . $self->message;
}

sub _true ( $, @ ) {
    return 1;
}

1;

__END__

=head1 NAME

GPForum::X - The base class of GPForum's exceptions.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    GPForum::X::Argument->throw( message => 'cache key is required' );

    try {
        $store->create($row);
    }
    catch ($error) {
        if ( my $conflict = GPForum::X::Conflict->caught($error) ) {
            return $self->_existing_row($row);
        }
        die $error;
    };

    "$error";               # the message, nothing else
    $error->location;       # "lib/GPForum/.../Store.pm line 42"

=head1 DESCRIPTION

An exception is an object with a C<message>, an optional C<cause>, a
C<failure_type> and the C<location> it was thrown from. It stringifies to its
message, so every C<like($error, qr/.../)>, C<index($error, ...)> and
C<trimmed> that read croak's strings keeps working, and it is true in boolean
context whatever its message says. ADR 0118 records the hierarchy:
L<GPForum::X::Argument>, L<GPForum::X::Config>, L<GPForum::X::Usage>,
L<GPForum::X::Conflict>, L<GPForum::X::Unavailable> and L<GPForum::X::Check>.

Refusals -- not found, forbidden, invalid input -- are not exceptions: they
are result values, because the command log records results and replays them.

=head1 SUBROUTINES/METHODS

=head2 new

Builds the exception. A missing or empty C<message> throws
L<GPForum::X::Argument>.

=head2 throw

Class method: builds the exception from its arguments and croaks it. Called
on an instance, croaks that instance. Records the caller as C<location> when
none is set.

=head2 rethrow

Croaks the exception again, keeping its location.

=head2 caught

Class method: the error when it is an instance of the class or a subclass,
undef otherwise.

=head2 TO_JSON

The message, so an exception placed in a JSON payload encodes as the string
it used to be.

=head1 DIAGNOSTICS

C<GPForum::X requires message> (an L<GPForum::X::Argument>) when built without
a message.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Carp>, L<Mojo::Base>, L<overload>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

C<location> is the line that called C<throw>; an exception built with C<new>
and croaked directly has none.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
