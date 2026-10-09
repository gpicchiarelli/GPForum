# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::BudgetSync;

use Carp qw(croak);
use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# The endpoint query budgets as gpforum migrate syncs them after the
# migrations: each sync is recorded, and answers with the rows it wrote and
# removed, or dies with the failure it was given.
has calls   => sub { return []; };
has failure => undef;                # optional: syncs without one
has written => 0;
has removed => sub { return []; };

sub sync_schema {
    my ( $self, $schema ) = @_;

    push @{ $self->calls }, $schema;
    croak $self->failure if defined $self->failure;

    return {
        removed => $self->removed,
        synced  => 25,
        written => $self->written,
    };
}

1;
