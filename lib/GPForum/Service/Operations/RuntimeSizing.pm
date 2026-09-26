# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::RuntimeSizing;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $MIN_PROCESS_COUNT => 1;
const my $MAX_WORKER_RATIO  => 8;

sub validate ( $self, $runtime ) {
    my %errors;
    _positive( \%errors, 'web_processes',      $runtime->web_processes );
    _positive( \%errors, 'worker_processes',   $runtime->worker_processes );
    _positive( \%errors, 'realtime_processes', $runtime->realtime_processes );

    if ( $runtime->worker_processes >
        $runtime->web_processes * $MAX_WORKER_RATIO )
    {
        $errors{worker_processes} = 'worker process count exceeds web ratio';
    }

    return {
        ok     => keys %errors ? 0 : 1,
        errors => \%errors,
    };
}

sub _positive ( $errors, $field, $value ) {
    if ( !defined $value || $value < $MIN_PROCESS_COUNT ) {
        $errors->{$field} = "$field must be positive";
    }

    return;
}

1;

