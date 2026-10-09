# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RecordingAuditRecorder;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# An event recorder that keeps each audit it is asked to write, as the
# arguments it was given, and answers that it wrote it.
has audits => sub { return []; };

sub record_audit ( $self, %audit ) {
    push @{ $self->audits }, \%audit;

    return { %audit, audit_id => scalar @{ $self->audits } };
}

1;
