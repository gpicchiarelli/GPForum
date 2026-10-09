# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OfflineCommandLog;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A command log whose database is gone: claiming a command id dies before the
# command runs, however a workflow asks for it.
sub result_of ( $, $ ) {
    die "command log offline\n";
}

sub run ( $, @ ) {
    die "command log offline\n";
}

1;
