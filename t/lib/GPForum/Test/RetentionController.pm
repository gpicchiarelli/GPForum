# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RetentionController;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# The few things GPForum::Service::Operations::ScheduledJobs->from_controller
# asks a controller for: the configuration and the clock it is given, and
# nothing to store or scan with -- the partitions job reads neither.
has config => undef;    # optional: none, as a controller without one
has clock  => undef;    # optional: the job's own otherwise

sub gp_config ($self) {
    return $self->config;
}

sub gp_clock ($self) {
    return $self->clock;
}

sub gp_antivirus ($self) {
    return undef;
}

sub gp_attachment_storage ($self) {
    return $self;
}

sub gp_attachment_store ($self) {
    return $self;
}

sub gp_schema ($self) {
    return undef;
}

1;
