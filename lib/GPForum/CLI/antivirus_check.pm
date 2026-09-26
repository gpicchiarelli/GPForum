# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

## no critic (NamingConventions::Capitalization)
# Lowercase on purpose: Mojolicious derives the command name an operator
# types from this class's basename.
package GPForum::CLI::antivirus_check;
## use critic

use strict;
use warnings;

use Mojo::Base 'Mojolicious::Command', -signatures;

use GPForum::Command::AntivirusCheck;
use GPForum::Command::Usage;

our $VERSION = '0.001';

# An adapter, not a reimplementation: the work stays in
# GPForum::Command::AntivirusCheck; this makes it discoverable as
# `gpforum antivirus_check`.
has description => 'Prove the upload antivirus detects a test file';
has usage       => sub ($self) {
    return GPForum::Command::AntivirusCheck->usage_text;
};

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->front_door(
        GPForum::Command::AntivirusCheck->new->run(@arguments) );
}

1;
