# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::MentionLog;

use v5.40;

our $VERSION = '0.001';

# A mention store that keeps every record_for_source call, so a test can
# count the writes whose mentions were recorded.
sub new ($class) {
    return bless { calls => [] }, $class;
}

sub record_for_source ( $self, $input ) {
    push @{ $self->{calls} }, $input;

    return { recorded => 1 };
}

sub calls ($self) {
    return $self->{calls};
}

1;
