# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OSWithEnvironmentFile;

use Mojo::Base 'GPForum::OS::Linux';
use v5.40;

our $VERSION = '0.001';

# The Linux profile, with the service's environment file wherever a test
# put one.
has environment_file => '/etc/gpforum/gpforum.env';

1;
