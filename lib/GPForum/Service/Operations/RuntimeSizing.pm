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

__END__

=head1 NAME

GPForum::Service::Operations::RuntimeSizing - Check that the web, worker and realtime process counts fit together.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $runtime = GPForum::Runtime->from_config($config);
    my $result =
      GPForum::Service::Operations::RuntimeSizing->new->validate($runtime);
    # { ok => 1, errors => {} }

=head1 DESCRIPTION

Checks a runtime's process counts: each of C<web_processes>,
C<worker_processes> and C<realtime_processes> must be at least 1, and there
may be no more than eight worker processes per web process.

=head1 SUBROUTINES/METHODS

=head2 validate

Takes an object with C<web_processes>, C<worker_processes> and
C<realtime_processes> accessors, such as L<GPForum::Runtime>. Returns
C<< { ok, errors } >>, the errors keyed by field: C<FIELD must be positive>
for a missing, zero or negative count, and
C<worker process count exceeds web ratio>
for C<worker_processes> when it is more than eight times
C<web_processes>.

=head1 DIAGNOSTICS

Problems are returned in C<errors>; nothing is thrown.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None beyond L<Mojo::Base> and L<Const::Fast>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
