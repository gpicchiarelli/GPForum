# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::UncountedConfig;

use Carp qw(croak);
use Mojo::Base 'GPForum::Config', -signatures;
use v5.40;

our $VERSION = '0.001';

# A configuration that dies when anything counts its CPUs, so a test can show
# what does.
sub automatic_web_processes ($self) {
    croak 'counted the CPUs';
}

1;
