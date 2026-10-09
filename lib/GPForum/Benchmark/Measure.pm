# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Benchmark::Measure;

use v5.40;

use Const::Fast;
use Exporter    qw(import);
use List::Util  qw(max sum0);
use Time::HiRes qw(time);

our $VERSION = '0.001';

our @EXPORT_OK = qw(
  average
  db_query_text
  endpoint_name
  error_count
  error_rate
  header_budget_status
  list_text
  nonzero
  overall_status
  percentile
  query_summary
  regressions
  rounded
  route_summary
  sample_route
  server_sample
  statuses_text
  threshold_for
  threshold_status
);

const my $PERCENT           => 100;
const my $MILLISECONDS      => 1_000;
const my $MIN_ELAPSED       => 0.000_001;
const my $HTTP_OK_MIN       => 200;
const my $HTTP_OK_MAX       => 399;
const my $DEFAULT_P95_LIMIT => 1_000;
const my $DEFAULT_P99_LIMIT => 2_000;
const my $DEFAULT_MIN_RPS   => 1;
const my $P50               => 50;
const my $P95               => 95;
const my $P99               => 99;

# The endpoint a route measures, by its path; a route that serves no page
# (health, metrics) has none.
const my @DYNAMIC_ROUTE_ENDPOINTS => (
    [ qr{\A /search/autocomplete}msx, 'search_autocomplete' ],
    [ qr{\A /c/}msx,                  'category_threads' ],
    [ qr{\A /t/}msx,                  'thread_view' ],
    [ qr{\A /search}msx,              'search' ],
);
const my %ROUTE_ENDPOINT => (
    q{/}           => 'home',
    q{/categories} => 'categories',
);

const my %THRESHOLD_BY_ENDPOINT => (
    home       => { p95_ms => 750, p99_ms => 1_500, min_req_per_sec => 1 },
    categories => { p95_ms => 500, p99_ms => 1_000, min_req_per_sec => 1 },
    category_threads =>
      { p95_ms => 1_000, p99_ms => 2_000, min_req_per_sec => 1 },
    thread_view => { p95_ms => 1_000, p99_ms => 2_000, min_req_per_sec => 1 },
    search      => { p95_ms => 1_000, p99_ms => 2_000, min_req_per_sec => 1 },
    search_autocomplete =>
      { p95_ms => 1_000, p99_ms => 2_000, min_req_per_sec => 1 },
);

sub endpoint_name ($route) {
    for my $mapping (@DYNAMIC_ROUTE_ENDPOINTS) {
        my ( $pattern, $name ) = @{$mapping};
        return $name if $route =~ $pattern;
    }

    return exists $ROUTE_ENDPOINT{$route} ? $ROUTE_ENDPOINT{$route} : undef;
}

sub threshold_for ($route) {
    my $name      = endpoint_name($route);
    my $threshold = defined $name ? $THRESHOLD_BY_ENDPOINT{$name} : undef;
    $threshold ||= {
        p95_ms          => $DEFAULT_P95_LIMIT,
        p99_ms          => $DEFAULT_P99_LIMIT,
        min_req_per_sec => $DEFAULT_MIN_RPS,
    };

    return { %{$threshold} };
}

sub threshold_status ( $p95, $p99, $rps, $threshold ) {
    return 'fail'
      if $p95 > $threshold->{p95_ms}
      || $p99 > $threshold->{p99_ms}
      || $rps < $threshold->{min_req_per_sec};

    return 'ok';
}

sub percentile ( $sorted, $percentile ) {
    return 0 if !@{$sorted};

    my $index = int( ( ( @{$sorted} - 1 ) * $percentile ) / $PERCENT );
    return $sorted->[$index];
}

sub average (@values) {
    return @values ? sum0(@values) / @values : 0;
}

sub rounded ($value) {
    return sprintf '%.3f', $value;
}

# An elapsed time to divide by: a run too fast for the clock took a
# microsecond rather than nothing.
sub nonzero ($value) {
    return $value > 0 ? $value : $MIN_ELAPSED;
}

sub error_count ($statuses) {
    my $count = 0;
    for my $status ( keys %{$statuses} ) {
        next if $status >= $HTTP_OK_MIN && $status <= $HTTP_OK_MAX;
        $count += $statuses->{$status};
    }

    return $count;
}

# The share of responses that were errors, three decimals.
sub error_rate ($statuses) {
    return rounded(
        error_count($statuses) / nonzero( sum0( values %{$statuses} ) ) );
}

sub statuses_text ($statuses) {
    return join q{,},
      map { $_ . q{:} . $statuses->{$_} } sort keys %{$statuses};
}

sub list_text ($values) {
    return 'none' if !@{$values};

    return join q{,}, @{$values};
}

sub db_query_text ($summary) {
    return 'not-observed' if !$summary || !$summary->{observed};

    return join q{,},
      'max=' . $summary->{max_queries},
      'avg=' . $summary->{avg_queries},
      'transactions=' . $summary->{max_transactions},
      'duplicates=' . $summary->{max_duplicate_queries},
      'budget=' . $summary->{budget_status};
}

# A route requested $iterations times through $request, which answers each
# request with its HTTP status, its elapsed milliseconds and, when the
# application reported them, the database queries it made.
sub sample_route ( $iterations, $request ) {
    my ( @latencies, @observations, %statuses );
    my $started = time;
    for ( 1 .. $iterations ) {
        my $sample = $request->();
        push @latencies, $sample->{elapsed_ms};
        if ( $sample->{db_query_stats} ) {
            push @observations, $sample->{db_query_stats};
        }
        $statuses{ $sample->{status} }++;
    }

    return {
        elapsed      => time - $started,
        latencies    => \@latencies,
        observations => \@observations,
        statuses     => \%statuses,
    };
}

# One request to a running server through $ua: its status, its elapsed
# milliseconds, and the queries the application reported in its headers.
sub server_sample ( $ua, $url ) {
    my $started = time;
    my $tx      = $ua->get($url);
    my $elapsed = ( time - $started ) * $MILLISECONDS;
    my $res     = $tx->result;

    return {
        status         => $res->code || 0,
        elapsed_ms     => $elapsed,
        db_query_stats => _header_query_stats( $res->headers ),
    };
}

sub _header_query_stats ($headers) {
    return {
        attached     => 1,
        queries      => _header_integer( $headers, 'X-GPForum-DB-Queries' ),
        transactions =>
          _header_integer( $headers, 'X-GPForum-DB-Transactions' ),
        duplicate_queries =>
          _header_integer( $headers, 'X-GPForum-DB-Duplicate-Queries' ),
        query_budget_status => $headers->header('X-GPForum-DB-Budget')
          || 'none',
    };
}

sub _header_integer ( $headers, $name ) {
    my $value = $headers->header($name);
    return 0 if !defined $value || $value !~ /\A [[:digit:]]+ \z/msx;

    return int $value;
}

# The query budget verdict the responses carried: any failure fails, any
# pass passes, and responses that carried none leave it at none.
sub header_budget_status ($observations) {
    my %seen =
      map { ( $_->{query_budget_status} || 'none' ) => 1 } @{$observations};

    return
        exists $seen{fail} ? 'fail'
      : exists $seen{ok}   ? 'ok'
      :                      'none';
}

# What a route's samples measured, and whether that passes: its endpoint's
# latency and throughput limits, no error responses, and -- where the queries
# were observed -- a query budget neither broken nor met with duplicates.
sub route_summary ( $route, $samples, $db_queries ) {
    my @sorted    = sort { $a <=> $b } @{ $samples->{latencies} };
    my $p95       = percentile( \@sorted, $P95 );
    my $p99       = percentile( \@sorted, $P99 );
    my $rps       = @sorted / nonzero( $samples->{elapsed} );
    my $threshold = threshold_for($route);
    my $failed =
         threshold_status( $p95, $p99, $rps, $threshold ) ne 'ok'
      || error_count( $samples->{statuses} ) > 0
      || _queries_failed($db_queries);

    return {
        route        => $route,
        status       => $failed ? 'fail' : 'ok',
        requests     => scalar @sorted,
        req_per_sec  => rounded($rps),
        p50_ms       => rounded( percentile( \@sorted, $P50 ) ),
        p95_ms       => rounded($p95),
        p99_ms       => rounded($p99),
        max_ms       => rounded( $sorted[-1] || 0 ),
        status_codes => $samples->{statuses},
        db_queries   => $db_queries,
        threshold    => $threshold,
    };
}

sub _queries_failed ($db_queries) {
    return 0 if !$db_queries->{observed};
    return 1 if $db_queries->{budget_status} eq 'fail';

    return $db_queries->{budget_status} ne 'none'
      && $db_queries->{max_duplicate_queries} > 0 ? 1 : 0;
}

# The most and the mean of the queries the observed requests made. The
# budget status is the caller's to judge: the in-process benchmark checks the
# maxima against the endpoint's budget, the server one reads the verdict each
# response carried.
sub query_summary ($observations) {
    return { observed => 0, budget_status => 'not-observed' }
      if !@{$observations};

    my %all;
    for my $count (qw(queries transactions duplicate_queries)) {
        $all{$count} = [ map { $_->{$count} || 0 } @{$observations} ];
    }

    return {
        observed              => 1,
        samples               => scalar @{$observations},
        max_queries           => max( 0, @{ $all{queries} } ),
        avg_queries           => rounded( average( @{ $all{queries} } ) ),
        max_transactions      => max( 0, @{ $all{transactions} } ),
        max_duplicate_queries => max( 0, @{ $all{duplicate_queries} } ),
        budget_status         => undef,
    };
}

# How a route fell behind its baseline: a p95 or p99 more than $tolerance
# slower, or a throughput more than $tolerance lower.
sub regressions ( $route, $baseline, $tolerance ) {
    my %allowed = (
        p95_ms => $baseline->{p95_ms} * ( 1 + $tolerance ),
        p99_ms => $baseline->{p99_ms} * ( 1 + $tolerance ),
    );
    my @over = grep { $route->{$_} > $allowed{$_} } qw(p95_ms p99_ms);

    # A baseline that served nothing sets no floor.
    if ( $baseline->{req_per_sec} ) {
        $allowed{req_per_sec} = $baseline->{req_per_sec} * ( 1 - $tolerance );
        if ( $route->{req_per_sec} < $allowed{req_per_sec} ) {
            push @over, 'req_per_sec';
        }
    }

    return map {
        +{
            metric   => $_,
            observed => $route->{$_},
            baseline => $baseline->{$_},
            allowed  => rounded( $allowed{$_} ),
        }
    } @over;
}

sub overall_status ($routes) {
    for my $route ( @{$routes} ) {
        return 'fail' if $route->{status} ne 'ok';
    }

    return 'ok';
}

1;

__END__

=head1 NAME

GPForum::Benchmark::Measure - What the benchmark commands measure, once.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use GPForum::Benchmark::Measure qw(percentile rounded threshold_for);

    my $p95       = percentile( [ sort { $a <=> $b } @latencies ], 95 );
    my $threshold = threshold_for('/t/thread-1');
    say rounded($p95), ' of ', $threshold->{p95_ms};

=head1 DESCRIPTION

The latency arithmetic, the per-endpoint thresholds and the report text that
L<GPForum::Command::Benchmark> (in process) and
L<GPForum::Command::HypnotoadBenchmark> (against a running server) share, so
the two measure a route by the same rules; L<GPForum::Command::QueryPlanEvidence>
shares the report text. Every function is exported on request only.

=head1 SUBROUTINES/METHODS

=head2 endpoint_name

The endpoint a route measures -- C<home>, C<categories>,
C<category_threads>, C<thread_view>, C<search>, C<search_autocomplete> -- or
undef for one that serves no page, such as C</health>.

=head2 threshold_for

A new hash reference with the route's C<p95_ms>, C<p99_ms> and
C<min_req_per_sec> limits: its endpoint's, or 1000, 2000 and 1.

=head2 threshold_status

Given p95, p99, requests per second and a threshold, C<fail> when any limit
is broken, C<ok> otherwise.

=head2 percentile

Given a sorted array reference and a percentile (0 to 100), the nearest-rank
value below it; 0 for no values.

=head2 average

The mean of the values, 0 for none.

=head2 rounded

The value with three decimals, as a string.

=head2 nonzero

An elapsed time safe to divide by: the value, or a microsecond when it is not
positive.

=head2 error_count

Given a hash of HTTP status counts, how many responses were neither 2xx nor
3xx.

=head2 error_rate

Given a hash of HTTP status counts, the share of responses that were neither
2xx nor 3xx, L</rounded>.

=head2 statuses_text

The status counts as C<200:5,404:1>, in status order.

=head2 list_text

Given an array reference, its values joined by commas, or C<none> when it is
empty.

=head2 db_query_text

A route's database query summary as one field of the report line, or
C<not-observed>.

=head2 sample_route

Given a number of iterations and a sub that makes one request and answers
C<< { status, elapsed_ms, db_query_stats } >>, the samples: a hash reference
with the C<latencies>, the C<statuses> counted, the C<elapsed> seconds and
the C<observations> of the requests that reported their queries.

=head2 server_sample

Given a L<Mojo::UserAgent> and a URL, one request's sample for
L</sample_route>: its C<status>, its C<elapsed_ms> and the
C<db_query_stats> the response's C<X-GPForum-DB-*> headers report.

=head2 header_budget_status

Given the C<db_query_stats> of a route's responses, the query budget verdict
they carried: C<fail> when any failed, else C<ok> when any passed, else
C<none>.

=head2 route_summary

Given a route, its samples and its query summary, the route's report: the
request count, requests per second, p50, p95, p99 and the slowest
milliseconds (each L</rounded>), the status counts, the query summary, the
threshold, and C<status> C<fail> when a limit is broken, a response was an
error, or observed queries broke their budget or repeated one.

=head2 query_summary

Given the observed query counts of a route's requests, their C<samples>,
C<max_queries>, C<avg_queries>, C<max_transactions> and
C<max_duplicate_queries>, with C<budget_status> undef for the caller to
judge; with none observed, C<observed> 0 and C<budget_status>
C<not-observed>.

=head2 regressions

Given a route report, its baseline and a tolerance (0.25 for 25%), the
violations: a C<p95_ms> or C<p99_ms> above the baseline's by more than the
tolerance, or a C<req_per_sec> below it by more, each with its C<metric>,
C<observed>, C<baseline> and C<allowed> values.

=head2 overall_status

C<ok> when every route report is C<ok>, C<fail> otherwise.

=head1 DIAGNOSTICS

None: the functions do not throw.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Exporter>, L<List::Util>, L<Time::HiRes>.

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
