# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::OperationsPayload;

use strict;
use warnings;
use feature 'signatures';

our $VERSION = '0.001';

sub metrics ( $, %input ) {
    return $input{snapshot} || {};
}

1;

__END__

=head1 NAME

GPForum::Web::OperationsPayload - The JSON body of the operations metrics endpoint.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $payload = GPForum::Web::OperationsPayload->metrics(
        snapshot => $metrics_snapshot->collect,
    );
    $controller->render( json => $payload );

=head1 DESCRIPTION

Keeps the shape of the operations metrics response out of
L<GPForum::Controller::Operations>, which only checks the metrics token and
renders what this class returns. The body is the metrics snapshot as
collected; nothing is added or renamed.

=head1 SUBROUTINES/METHODS

=head2 metrics

Class method. Takes a list of key/value pairs; C<snapshot> is the hash
reference collected by L<GPForum::Service::Operations::MetricsSnapshot>.
Returns that hash reference unchanged, or an empty hash reference when no
snapshot (or a false one) is given.

=head1 DIAGNOSTICS

None. It never dies.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None beyond core Perl.

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
