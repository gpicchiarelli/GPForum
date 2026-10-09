# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

## no critic (NamingConventions::Capitalization)
# Lowercase on purpose: the front door and Mojolicious derive the command an
# operator types from this class's basename, so GPForum::CLI::Backup would
# be invoked as `gpforum Backup`.
package GPForum::CLI::backup;
## use critic

use Mojo::Base 'Mojolicious::Command', -signatures;
use v5.40;

use GPForum::CLI::FrontDoor::Launcher;
use GPForum::Command::Backup;
use GPForum::Command::Usage;

our $VERSION = '0.001';

# `gpforum backup [--to DIR]`. The work is GPForum::Command::Backup's; a
# relative --to, and the backup without one, start where the operator typed
# the command, which the front door remembers before it moves to the code
# directory.
has description => 'Back up the database and the uploads';
has usage       => sub ($self) {
    return GPForum::Command::Backup->usage_text;
};

sub run ( $self, @arguments ) {
    my $typed_in = GPForum::CLI::FrontDoor::Launcher->typed_in;

    return GPForum::Command::Usage->front_door(
        GPForum::Command::Backup->new(
            defined $typed_in ? ( directory => $typed_in ) : ()
        )->run(@arguments)
    );
}

1;
