# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::HostConfig;

use Const::Fast;
use Mojo::Base 'GPForum::Config', -signatures;
use v5.40;

our $VERSION = '0.001';

const my $GIGABYTE => 1_024**3;

# A configuration on a host the test describes -- { cpus, memory_bytes } --
# instead of the one the suite runs on: one CPU and 1 GB unless told.
has host => sub { return { cpus => 1, memory_bytes => $GIGABYTE } };

sub host_worker_cpus ($self) {
    return $self->host->{cpus};
}

sub host_cpus ($self) {
    return $self->host->{cpus};
}

sub host_memory_bytes ($self) {
    return $self->host->{memory_bytes};
}

1;
