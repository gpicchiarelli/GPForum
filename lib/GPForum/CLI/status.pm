# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

## no critic (NamingConventions::Capitalization)
# Lowercase on purpose: the front door and Mojolicious derive the command an
# operator types from this class's basename, so GPForum::CLI::Status would be
# invoked as `gpforum Status`.
package GPForum::CLI::status;
## use critic

use Mojo::Base 'Mojolicious::Command', -signatures;
use v5.40;

use GPForum::Command::Status;
use GPForum::Command::Usage;

our $VERSION = '0.001';

# `gpforum status`. The work is GPForum::Command::Status's.
has description => 'Ask the running forum how it is';
has usage       => sub ($self) {
    return GPForum::Command::Status->usage_text;
};

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->front_door(
        GPForum::Command::Status->new->run(@arguments) );
}

1;
