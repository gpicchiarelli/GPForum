# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ReputationLedger;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls => sub { return []; };

sub record_event {
    my ( $self, $input ) = @_;

    push @{ $self->calls }, $input;

    return {
        event    => $input,
        ok       => 1,
        snapshot => {
            score       => $input->{delta},
            trust_level => 0,
            user_id     => $input->{user_id},
        },
    };
}

1;
