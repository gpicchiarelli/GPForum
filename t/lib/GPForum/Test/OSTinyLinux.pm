# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OSTinyLinux;

use strict;
use warnings;

use Mojo::Base 'GPForum::OS::Linux';

our $VERSION = '0.001';

sub cpu_count {
    return 1;
}

1;
