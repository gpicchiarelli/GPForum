# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::Transaction;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Try::Tiny;

our $VERSION = '0.001';

# Row sets a fake resultset keeps. Snapshotting these and putting them back
# when the transaction body dies is the closest a fake gets to a rollback.
const my @ROW_SET_ACCESSOR => qw(created created_objects rows);

sub run {
    my ( $resultsets, $code ) = @_;

    my $snapshot = _snapshot($resultsets);

    my $result;
    my $failure;
    try {
        $result = $code->();
    }
    catch {
        $failure = $_;
    };
    if ($failure) {
        _restore($snapshot);
        croak $failure;
    }

    return $result;
}

sub _snapshot {
    my ($resultsets) = @_;

    my @entries;
    for my $resultset ( @{$resultsets} ) {
        push @entries, _snapshot_resultset($resultset);
    }

    return \@entries;
}

sub _snapshot_resultset {
    my ($resultset) = @_;

    my @entries;
    for my $accessor (@ROW_SET_ACCESSOR) {
        next if !_holds_row_set( $resultset, $accessor );
        push @entries,
          {
            accessor  => $accessor,
            held      => _copied( $resultset->$accessor ),
            resultset => $resultset,
          };
    }

    return @entries;
}

sub _copied {
    my ($held) = @_;

    return [ @{$held} ] if ref $held eq 'ARRAY';

    return { %{$held} };
}

sub _holds_row_set {
    my ( $resultset, $accessor ) = @_;

    return 0 if !ref $resultset;
    return 0 if !$resultset->can($accessor);

    return ref $resultset->$accessor ? 1 : 0;
}

sub _restore {
    my ($snapshot) = @_;

    for my $entry ( @{$snapshot} ) {
        _restore_entry($entry);
    }

    return;
}

sub _restore_entry {
    my ($entry) = @_;

    my $accessor = $entry->{accessor};
    my $held     = $entry->{held};

    return _restore_list( $entry->{resultset}->$accessor, $held )
      if ref $held eq 'ARRAY';

    return _restore_map( $entry->{resultset}->$accessor, $held );
}

sub _restore_list {
    my ( $live, $held ) = @_;

    @{$live} = @{$held};

    return;
}

sub _restore_map {
    my ( $live, $held ) = @_;

    %{$live} = %{$held};

    return;
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
sets and rethrowing when the body dies.

=head1 DIAGNOSTICS

Rethrows the failure raised by the transaction body.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Carp>, L<Const::Fast>, and L<Try::Tiny>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Restores row membership, not field values mutated in place, and does not
nest: an inner transaction restores only what it snapshotted.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
