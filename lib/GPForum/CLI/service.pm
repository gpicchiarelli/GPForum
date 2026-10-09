# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

## no critic (NamingConventions::Capitalization)
# Lowercase on purpose: the front door and Mojolicious derive the command an
# operator types from this class's basename, so GPForum::CLI::Service would
# be invoked as `gpforum Service`.
package GPForum::CLI::service;
## use critic

use Mojo::Base 'Mojolicious::Command', -signatures;
use v5.40;

use GPForum::CLI::FrontDoor::Launcher;
use GPForum::Command::Service;
use GPForum::Command::Usage;

our $VERSION = '0.001';

# `gpforum service print [TARGET]`. The work is GPForum::Command::Service's;
# a relative --to starts where the operator typed the command, which the
# front door remembers before it moves to the code directory.
has description => 'Print the service files, written for this host';
has usage       => sub ($self) {
    return GPForum::Command::Service->usage_text;
};

sub run ( $self, @arguments ) {
    my $typed_in = GPForum::CLI::FrontDoor::Launcher->typed_in;

    return GPForum::Command::Usage->front_door(
        GPForum::Command::Service->new(
            defined $typed_in ? ( directory => $typed_in ) : ()
        )->run(@arguments)
    );
}

1;
