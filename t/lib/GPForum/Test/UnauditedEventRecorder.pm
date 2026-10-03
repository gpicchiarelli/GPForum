# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::UnauditedEventRecorder;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base 'GPForum::Infrastructure::EventRecorder';

our $VERSION = '0.001';

# The real event recorder, whose events and outbox messages reach the
# database, but whose audit write fails, as a statement or lock timeout
# would: whatever the caller wrote before the audit stays only if it was
# not written in the audit's transaction.
sub record_audit {
    croak 'audit write failed';
}

1;
