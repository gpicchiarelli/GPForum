# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimeId;

use v5.40;

our $VERSION = '0.001';

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub uuid {
    return 'event-1';
}

1;
