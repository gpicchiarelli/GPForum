# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Benchmark::HypnotoadText;

use v5.40;

use Exporter qw(import);

use GPForum::Benchmark::Measure qw(db_query_text list_text statuses_text);

our $VERSION = '0.001';

our @EXPORT_OK = qw(text_report);

# The run on one line -- with the server's workers and, behind a proxy, the
# proxy -- then the OS evidence when there is any, then a line per route.
sub text_report ($report) {
    my $runtime = $report->{runtime};
    my $text =
        "mode=$report->{mode} status=$report->{status}"
      . " iterations=$report->{iterations} warmup=$report->{warmup}"
      . " dataset_profile=$report->{dataset}{profile}";
    if ($runtime) {
        $text .= join q{ }, q{},
          "workers=$runtime->{workers_requested}",
          'master_pid=' . _known( $runtime->{master_pid} ),
          'worker_pids=' . list_text( $runtime->{worker_pids} || [] );
        if ( $runtime->{reverse_proxy} ) {
            $text .= q{ } . _reverse_proxy_text( $runtime, $report );
        }
    }
    $text .= "\n";
    if ( $runtime && $runtime->{os_evidence} ) {
        $text .= _os_evidence_line( $runtime->{os_evidence} );
    }

    for my $route ( @{ $report->{routes} || [] } ) {
        next if ref $route ne 'HASH';
        $text .= _route_line($route);
    }

    return $text;
}

sub _os_evidence_line ($evidence) {
    return join q{ },
      'os_evidence_status=' . _known( $evidence->{status} ),
      'declared_event_backend='
      . _known( $evidence->{event_loop}{declared_backend} ),
      'actual_reactor='
      . _known( $evidence->{event_loop}{actual_reactor_class} ),
      'reuseport_configured='
      . ( $evidence->{hypnotoad}{reuseport_configured} || 0 ),
      'reuseport_verified='
      . ( $evidence->{socket_options}{reuseport}{verified} || 0 ),
      'sendfile_materialized='
      . ( $evidence->{static_transfer}{materialized_in_benchmark} || 0 ),
      'postgresql_settings='
      . ( $evidence->{postgresql}{available} ? 'available' : 'unavailable' ),
      'temp_mount=' . _known( $evidence->{filesystem}{df}{mounted_on} ),
      "\n";
}

sub _reverse_proxy_text ( $runtime, $report ) {
    my $proxy    = $runtime->{reverse_proxy}     || {};
    my $frontend = $runtime->{frontend}          || {};
    my $backend  = $runtime->{backend_hypnotoad} || {};
    my $direct   = ( $report->{comparison}   || {} )->{direct_enabled};
    my $version  = _known( $proxy->{version} || $proxy->{status} );

    return join q{ },
      'proxy=' . _known( $proxy->{name} || $proxy->{requested} ),
      'proxy_version=' . ( $version =~ s/\s+/_/gmsxr ),
      'frontend_port=' . _known( $frontend->{port} ),
      'frontend_url=' . _known( $frontend->{base_url} ),
      'backend_hypnotoad=' . _known( $backend->{base_url} ),
      'direct_comparison=' . ( $direct ? 'enabled' : 'off' );
}

sub _route_line ($route) {
    return join q{ },
      ( map { "$_=$route->{$_}" }
          qw(route status requests req_per_sec p50_ms p95_ms p99_ms error_rate)
      ),
      'query_budget=' . ( $route->{query_budget} // 'none' ),
      'db_queries=' . db_query_text( $route->{db_queries} ),
      'comparison='
      . ( $route->{comparison} ? $route->{comparison}{status} : 'not-checked' ),
      'statuses=' . statuses_text( $route->{status_codes} ),
      "\n";
}

sub _known ($value) {
    return $value || 'unknown';
}

1;

__END__

=head1 NAME

GPForum::Benchmark::HypnotoadText - The hypnotoad benchmark's text report.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use GPForum::Benchmark::HypnotoadText qw(text_report);

    print text_report($report);

=head1 DESCRIPTION

Renders the report L<GPForum::Command::HypnotoadBenchmark> builds as the
C<key=value> lines an operator reads and a CI log keeps.

=head1 SUBROUTINES/METHODS

=head2 text_report

Given a report, its text: the run's line (mode, status, iterations, warmup,
dataset profile, and with a runtime its workers, master and worker pids and
any reverse proxy), the OS evidence line when the runtime carries one, and a
line per measured route.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Exporter>, L<GPForum::Benchmark::Measure>.

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
