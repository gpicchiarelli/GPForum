# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::Process;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $DEFAULT_NICE_DELTA => 0;
const my %PROCESS_CLASSES => (
    web_worker         => 0,
    projection_worker  => 5,
    mail_worker        => 8,
    search_worker      => 5,
    maintenance_worker => 10,
);

sub snapshot ( $self, $features ) {
    my %classes;
    for my $class ( sort keys %PROCESS_CLASSES ) {
        $classes{$class} = $self->priority_plan( $class, $features );
    }

    return {
        classes => \%classes,
        policy  => 'descriptive-unless-explicitly-enabled',
    };
}

sub priority_plan ( $self, $class, $features ) {
    my $known   = exists $PROCESS_CLASSES{$class} ? 1 : 0;
    my $delta   = $known ? $PROCESS_CLASSES{$class}   : $DEFAULT_NICE_DELTA;
    my $enabled = _worker_priority_enabled($features);

    return {
        class      => $class,
        known      => $known,
        nice_delta => $delta,
        enabled    => $enabled,
        action     => $enabled ? 'setpriority-if-permitted' : 'observe',
    };
}

sub _worker_priority_enabled ($features) {
    return 0 if !$features;
    return 0 if !exists $features->{worker_priority};

    return $features->{worker_priority}{enabled} ? 1 : 0;
}

1;
