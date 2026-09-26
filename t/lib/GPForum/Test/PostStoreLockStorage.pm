# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PostStoreLockStorage;

use strict;
use warnings;

use Mojo::Base 'GPForum::Test::Storage';

our $VERSION = '0.001';

has lock_dbh => undef;

# Callers have always spelled the injected handle `dbh`, which now names a
# method on the parent. Keep the spelling and store it under lock_dbh.
sub new {
    my ( $class, %attributes ) = @_;

    if ( exists $attributes{dbh} ) {
        $attributes{lock_dbh} = delete $attributes{dbh};
    }

    return $class->SUPER::new(%attributes);
}

sub dbh {
    my ($self) = @_;

    my $injected = $self->lock_dbh;
    if ( !$injected ) {
        return $self->SUPER::dbh;
    }

    # GPForum::Infrastructure::UniqueConflict reads AutoCommit off the handle
    # to decide whether a savepoint is possible, so the injected spy has to
    # carry it too or conflict recovery silently degrades.
    $injected->{AutoCommit} = $self->txn_depth ? 0 : 1;

    return $injected;
}

1;

__END__

=head1 NAME

GPForum::Test::PostStoreLockStorage - Storage double that records row locks.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $storage = GPForum::Test::PostStoreLockStorage->new( dbh => $spy );

=head1 DESCRIPTION

L<GPForum::Test::Storage> with an injected handle so a test can observe the
advisory-lock statements a store issues, while keeping the savepoint surface
conflict recovery depends on.

=head1 SUBROUTINES/METHODS

=head2 new

Accepts the historical C<dbh> spelling for the injected handle.

=head2 dbh

Returns the injected handle, with C<AutoCommit> reflecting transaction depth,
or the parent's handle when none was injected.

=head1 DIAGNOSTICS

This module does not throw its own exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Test::Storage>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Giacomo Picchiarelli. BSD-3-Clause.

=cut
