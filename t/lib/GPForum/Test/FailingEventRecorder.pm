# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::FailingEventRecorder;

use Carp qw(croak);
use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# An event recorder whose event write fails, as a statement or lock timeout
# would, after the caller has written whatever came before it.
sub record_event {
    croak 'event write failed';
}

sub record_audit {
    croak 'audit write failed';
}

1;
