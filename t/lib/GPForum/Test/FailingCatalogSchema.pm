# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::FailingCatalogSchema;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A schema whose catalog lookup breaks at one step: reading its storage, its
# handle, the DBMS name, or the partition index family. What
# GPForum::X::Conflict->on reads to match a partition's index, when it cannot.
# With no step to fail it answers as PostgreSQL with the family it is given.
has fail_at => undef;               # optional: storage, dbh, get_info or select
has dbms    => 'PostgreSQL';
has family  => sub { return []; };
has lookups => sub { return []; };

sub storage ($self) {
    $self->_step('storage');
    return $self;
}

sub dbh ($self) {
    $self->_step('dbh');
    return $self;
}

sub get_info ( $self, $ ) {
    $self->_step('get_info');
    return $self->dbms;
}

sub selectcol_arrayref ( $self, $sql, $attributes, $constraint ) {
    $self->_step('select');
    push @{ $self->lookups }, $constraint;
    return $self->family;
}

sub _step ( $self, $step ) {
    if ( ( $self->fail_at // q{} ) eq $step ) {
        die "catalog $step failed\n";
    }

    return;
}

1;
