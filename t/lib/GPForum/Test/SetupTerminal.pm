# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SetupTerminal;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# The terminal gpforum setup asks its questions at, typed by a test: the
# lines answered in turn, the hidden ones for a password, and every
# question asked, kept to compare.
has interactive => 1;
has lines       => sub { return []; };
has hidden      => sub { return []; };
has asked       => sub { return []; };

sub is_interactive ($self) {
    return $self->interactive;
}

sub line ( $self, $question ) {
    push @{ $self->asked }, $question;

    return shift @{ $self->lines };
}

sub hidden_line ( $self, $question ) {
    push @{ $self->asked }, $question;

    return shift @{ $self->hidden };
}

1;
