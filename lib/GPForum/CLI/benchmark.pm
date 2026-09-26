# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

## no critic (NamingConventions::Capitalization)
# Lowercase on purpose: Mojolicious derives the command name an operator
# types from this class's basename, so GPForum::CLI::Migrate would be
# invoked as `gpforum Migrate`.
package GPForum::CLI::benchmark;
## use critic

use strict;
use warnings;

use Mojo::Base 'Mojolicious::Command', -signatures;

use GPForum::Command::Benchmark;
use GPForum::Command::Usage;

our $VERSION = '0.001';

# An adapter, not a reimplementation: bin/gpforum registered no command
# namespace, so `gpforum` listed Mojolicious's own commands -- including
# cpanify, "Upload distribution to CPAN" -- and none of this project's. The
# work stays in GPForum::Command::Benchmark; this makes it discoverable.
has description =>
  'Benchmark the application against a fixture or a live configuration';
has usage => sub ($self) {
    return GPForum::Command::Benchmark->usage_text;
};

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->front_door(
        GPForum::Command::Benchmark->new->run(@arguments) );
}

1;
