# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

## no critic (NamingConventions::Capitalization)
# Lowercase on purpose: the front door and Mojolicious derive the command an
# operator types from this class's basename, so GPForum::CLI::Setup would be
# invoked as `gpforum Setup`.
package GPForum::CLI::setup;
## use critic

use Mojo::Base 'Mojolicious::Command', -signatures;
use v5.40;

use GPForum::Command::Setup;
use GPForum::Command::Usage;

our $VERSION = '0.001';

# `gpforum setup`. The work is GPForum::Command::Setup's.
has description => 'Set this host up: the settings, the database, the schema';
has usage       => sub ($self) {
    return GPForum::Command::Setup->usage_text;
};

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->front_door(
        GPForum::Command::Setup->new->run(@arguments) );
}

1;
