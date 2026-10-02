# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ScriptedId;

use strict;
use warnings;

use Mojo::Base 'GPForum::Infrastructure::Id';

our $VERSION = '0.001';

# Real uuids, after the ones a test lines up first. Handing a store an id
# that is already stored is the only way to make PostgreSQL raise, on
# purpose, the primary-key conflict the store has to recover from.
has next_ids => sub { return []; };

sub uuid {
    my ($self) = @_;

    my $scripted = shift @{ $self->next_ids };

    return $scripted // $self->SUPER::uuid;
}

1;
