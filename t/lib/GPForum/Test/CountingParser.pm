# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CountingParser;

use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Support::ServiceEnvironment;

our $VERSION = '0.001';

# The environment file's parser, counting the lines it is asked to read: a
# file read again shows as more lines.
has lines => 0;

sub loaded ($self) {
    return undef;
}

sub parse_line ( $self, $line ) {
    $self->lines( $self->lines + 1 );

    return GPForum::Command::Support::ServiceEnvironment->parse_line($line);
}

1;
