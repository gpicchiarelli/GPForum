# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RecordingEvidenceService;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# An evidence service (stress-load's load, staging-host-verify's verify) that
# passes and keeps the options it was run with, so a test reads what the
# command's parser handed the work.
has 'options';

sub run ( $self, $options ) {
    $self->options($options);

    return { status => 'pass' };
}

sub format_evidence ( $self, $evidence, $format ) {
    return q{};
}

sub exit_status ( $self, $evidence ) {
    return 0;
}

1;
