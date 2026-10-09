# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

## no critic (NamingConventions::Capitalization)
# Lowercase on purpose: the front door and Mojolicious derive the command an
# operator types from this class's basename, so GPForum::CLI::Upgrade would
# be invoked as `gpforum Upgrade`.
package GPForum::CLI::upgrade;
## use critic

use Mojo::Base 'Mojolicious::Command', -signatures;
use v5.40;

use GPForum::Command::Upgrade;
use GPForum::Command::Usage;

our $VERSION = '0.001';

# `gpforum upgrade`. The work is GPForum::Command::Upgrade's.
has description => 'Print the commands that upgrade this forum';
has usage       => sub ($self) {
    return GPForum::Command::Upgrade->usage_text;
};

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->front_door(
        GPForum::Command::Upgrade->new->run(@arguments) );
}

1;
