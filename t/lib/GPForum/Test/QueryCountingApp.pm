# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::QueryCountingApp;

use Mojo::Base 'Mojolicious', -signatures;
use v5.40;

use GPForum::Service::Operations::DbQueryStats;
use GPForum::Test::DbQueryStatsSchema;

our $VERSION = '0.001';

# An application for the in-process benchmark (Command::Benchmark's
# app_class) that counts two queries for every request, and answers
# gp_db_query_stats with the counter of the route it served last: /attached
# counts on a counter attached to a schema, /detached on one that is not, so
# its requests are not this request's count.
sub startup ($self) {
    $self->log->level('fatal');

    my $attached = GPForum::Service::Operations::DbQueryStats->new;
    $attached->attach_to_schema( GPForum::Test::DbQueryStatsSchema->new );
    my $detached = GPForum::Service::Operations::DbQueryStats->new;
    my $served   = $detached;

    $self->helper( gp_db_query_stats => sub { return $served; } );
    $self->routes->get(
        '/attached' => sub ($controller) {
            $served = $attached;
            return _serve( $controller, $attached, q{/attached} );
        }
    );
    $self->routes->get(
        '/detached' => sub ($controller) {
            $served = $detached;
            return _serve( $controller, $detached, q{/detached} );
        }
    );

    return;
}

sub _serve ( $controller, $stats, $route ) {
    my $token = $stats->start_request( { route => $route } );
    $stats->query_start('SELECT 1');
    $stats->query_start('SELECT 2');
    $stats->finish_request( $token, { status => 200 } );

    return $controller->render( text => 'ok' );
}

1;

__END__

=head1 NAME

GPForum::Test::QueryCountingApp - An application whose requests each count two queries.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    GPForum::Command::Benchmark->new( app_class => 'GPForum::Test::QueryCountingApp' )
      ->benchmark_report( '--configured', '--route', '/attached' );

=head1 DESCRIPTION

Serves C</attached> and C</detached>. Each request runs two distinct queries
through a L<GPForum::Service::Operations::DbQueryStats>; the C</attached>
counter is attached to a schema, the C</detached> one is not, and the
C<gp_db_query_stats> helper answers the counter of the route served last.

=head1 SUBROUTINES/METHODS

=head2 startup

Registers the helper and the two routes.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojolicious>, L<GPForum::Service::Operations::DbQueryStats>,
L<GPForum::Test::DbQueryStatsSchema>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The served counter is shared by every controller of one application, which
is what a benchmark reading it right after its request needs.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
