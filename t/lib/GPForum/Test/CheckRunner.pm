# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CheckRunner;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A migration runner for migrate --check: every applied file as it was
# recorded, and the migrations given still to apply.
has pending => sub { return [] };

sub verify_applied ($self) {
    return 1;
}

1;
