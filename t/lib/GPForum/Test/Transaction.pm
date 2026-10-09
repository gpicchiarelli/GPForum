# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::Transaction;

use v5.40;

use Carp qw(croak);

use GPForum::Test::RowState;

our $VERSION = '0.001';

# Snapshotting the resultsets' row sets and the rows' columns, and putting
# them back when the transaction body dies, is the closest a fake gets to a
# rollback.
sub run {
    my ( $resultsets, $code ) = @_;

    my $snapshot =
      GPForum::Test::RowState::capture_resultsets( @{$resultsets} );

    my $result;
    my $failure;
    try {
        $result = $code->();
    }
    catch ($error) {
        $failure = $error;
    };
    if ($failure) {
        GPForum::Test::RowState::restore($snapshot);
        croak $failure;
    }

    return $result;
}

1;

__END__

=head1 NAME

GPForum::Test::Transaction - Rollback helper for in-memory test schemas.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    sub txn_do {
        my ( $self, $code ) = @_;

        return GPForum::Test::Transaction::run(
            [ values %{ $self->resultsets } ], $code );
    }

=head1 DESCRIPTION

Gives the fake schemas the one transaction property tests rely on: a body
that dies leaves no rows behind. The snapshot is taken before the body runs
and copied back into the live containers on failure, so row identity and any
container reference a test already holds survive the rollback.

=head1 SUBROUTINES/METHODS

=head2 run

Runs a transaction body over the given fake resultsets, restoring their row
sets and the rows' columns and rethrowing when the body dies.

=head1 DIAGNOSTICS

Rethrows the failure raised by the transaction body.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Carp> and L<GPForum::Test::RowState>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Restores row membership and each row's columns one level deep, and does not
nest: an inner transaction restores only what it snapshotted.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
