# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

## no critic (NamingConventions::Capitalization)
# Lowercase on purpose: the front door and Mojolicious derive the command an
# operator types from this class's basename, so GPForum::CLI::Doctor would be
# invoked as `gpforum Doctor`.
package GPForum::CLI::doctor;
## use critic

use Mojo::Base 'Mojolicious::Command', -signatures;
use v5.40;

use GPForum::Command::Doctor;
use GPForum::Command::Usage;

our $VERSION = '0.001';

# `gpforum doctor`. The work is GPForum::Command::Doctor's.
has description =>
  'Check the settings, the host and the services, with the fixes';
has usage => sub ($self) {
    return GPForum::Command::Doctor->usage_text;
};

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->front_door(
        GPForum::Command::Doctor->new->run(@arguments) );
}

1;
