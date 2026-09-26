# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ScriptedParticipation;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# A suspension store whose can_participate does whatever the test scripts:
# answer, answer nothing, or die as a store that cannot be reached does.
has answer => sub {
    return sub { return { ok => 1 }; };
};

sub can_participate {
    my ($self) = @_;

    return $self->answer->();
}

1;
