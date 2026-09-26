# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

## no critic (NamingConventions::Capitalization)
# Lowercase on purpose: Mojolicious derives the command name an operator
# types from this class's basename, so GPForum::CLI::Migrate would be
# invoked as `gpforum Migrate`.
package GPForum::CLI::dead_letter_replay;
## use critic

use strict;
use warnings;

use Mojo::Base 'Mojolicious::Command', -signatures;

use GPForum::Command::DeadLetterReplay;
use GPForum::Command::Usage;

our $VERSION = '0.001';

# An adapter, not a reimplementation: bin/gpforum registered no command
# namespace, so `gpforum` listed Mojolicious's own commands -- including
# cpanify, "Upload distribution to CPAN" -- and none of this project's. The
# work stays in GPForum::Command::DeadLetterReplay; this makes it discoverable.
has description => 'Review and replay dead letters';
has usage       => sub ($self) {
    return GPForum::Command::DeadLetterReplay->usage_text;
};

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->front_door(
        GPForum::Command::DeadLetterReplay->new->run(@arguments) );
}

1;
