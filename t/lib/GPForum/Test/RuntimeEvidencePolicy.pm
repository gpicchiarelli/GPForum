# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RuntimeEvidencePolicy;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# A runtime policy whose report is the one it was given, so OS::RuntimeEvidence
# can be read against a Hypnotoad configuration chosen by the test.

has report => sub { return { status => 'ok' }; };

1;
