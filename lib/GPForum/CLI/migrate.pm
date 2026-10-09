# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

## no critic (NamingConventions::Capitalization)
# Lowercase on purpose: Mojolicious derives the command name an operator
# types from this class's basename, so GPForum::CLI::Migrate would be
# invoked as `gpforum Migrate`.
package GPForum::CLI::migrate;
## use critic

use Mojo::Base 'Mojolicious::Command', -signatures;
use v5.40;

use GPForum::Command::Migrate;
use GPForum::Command::Usage;

our $VERSION = '0.001';

# An adapter, not a reimplementation: the work stays in
# GPForum::Command::Migrate. `gpforum migrate` does it -- the migrations, the
# partition window, the query budgets -- where bin/gpforum-migrate, its
# alias, still plans unless told --apply.
has description => 'Bring the database up to date';
has usage       => sub ($self) {
    return GPForum::Command::Migrate->new( default_mode => 'apply' )
      ->usage_text;
};

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->front_door(
        GPForum::Command::Migrate->new( default_mode => 'apply' )
          ->run(@arguments) );
}

1;
