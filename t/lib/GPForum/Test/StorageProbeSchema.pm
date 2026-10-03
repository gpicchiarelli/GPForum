# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::StorageProbeSchema;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A schema that is its own storage, for t/324-storage.t. `fails` names the
# step that goes wrong: storage or dbh dies, storage is undef (no_storage),
# or the storage has no dbh method (no_dbh).
has fails  => sub { return {}; };
has handle => 'database handle';

sub storage ($self) {
    my $fails = $self->fails;
    if ( $fails->{storage} ) {
        die "storage is gone\n";
    }
    if ( $fails->{no_storage} ) {
        return undef;
    }
    if ( $fails->{no_dbh} ) {
        return Mojo::Base->new;
    }

    return $self;
}

sub dbh ($self) {
    if ( $self->fails->{dbh} ) {
        die "could not connect to server\n";
    }

    return $self->handle;
}

1;
