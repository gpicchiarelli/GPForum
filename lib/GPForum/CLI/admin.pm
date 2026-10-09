# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

## no critic (NamingConventions::Capitalization)
# Lowercase on purpose: the front door and Mojolicious derive the command an
# operator types from this class's basename, so GPForum::CLI::Admin would be
# invoked as `gpforum Admin`.
package GPForum::CLI::admin;
## use critic

use Mojo::Base 'Mojolicious::Command', -signatures;
use v5.40;

use GPForum::Command::AdminBootstrap;
use GPForum::Command::Usage;

our $VERSION = '0.001';

# `gpforum admin create` and `gpforum admin grant`. The work is
# GPForum::Command::AdminBootstrap's, which bin/gpforum-admin-bootstrap and
# `gpforum admin-bootstrap` run too.
has description => q{Create the forum's owner, or make a member one};
has usage       => sub ($self) {
    return GPForum::Command::AdminBootstrap->usage_text;
};

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->front_door(
        GPForum::Command::AdminBootstrap->new->run(@arguments) );
}

1;
