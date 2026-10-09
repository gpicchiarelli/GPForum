# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SeedOptionsRecorder;

use Mojo::Base 'GPForum::Command::PerformanceSeed', -signatures;
use v5.40;

our $VERSION = '0.001';

# performance-seed with the database left out: seed answers with the options
# it was asked to seed, so a test reads the dataset a profile names.
sub seed ( $self, $options ) {
    return $options;
}

1;
