# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

## no critic (NamingConventions::Capitalization)
# Lowercase on purpose: the front door and Mojolicious derive the command an
# operator types from this class's basename, so GPForum::CLI::Secret would be
# invoked as `gpforum Secret`.
package GPForum::CLI::secret;
## use critic

use Mojo::Base 'Mojolicious::Command', -signatures;
use v5.40;

use GPForum::Command::Secret;
use GPForum::Command::Usage;

our $VERSION = '0.001';

# `gpforum secret rotate session|metrics`. The work is
# GPForum::Command::Secret's.
has description => 'Rotate the session secret or the metrics token';
has usage       => sub ($self) {
    return GPForum::Command::Secret->usage_text;
};

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->front_door(
        GPForum::Command::Secret->new->run(@arguments) );
}

1;
