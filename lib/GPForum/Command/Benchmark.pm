package GPForum::Command::Benchmark;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json encode_json);
use Mojo::Base -base;
use Test::Mojo;
use Time::HiRes qw(time);

use GPForum::Benchmark::FixtureServices;
use GPForum::Service::Operations::QueryBudget;

our $VERSION = '0.001';

const my $DEFAULT_ITERATIONS => 50;
const my $DEFAULT_WARMUP     => 5;
const my $MILLISECONDS       => 1_000;
const my $PERCENT            => 100;
const my $P50                => 50;
const my $P95                => 95;
const my $P99                => 99;
const my $MIN_ELAPSED        => 0.000_001;
const my $DEFAULT_P95_LIMIT  => 1_000;
const my $DEFAULT_P99_LIMIT  => 2_000;
const my $DEFAULT_MIN_RPS    => 1;
const my %ROUTE_ENDPOINT => (
    q{/}             => 'home',
    q{/categories}   => 'categories',
    q{/health}       => undef,
    q{/health/live}  => undef,
    q{/health/ready} => undef,
    q{/metrics}      => undef,
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
const my @DEFAULT_ROUTES => (
    q{/},                 q{/categories},
    q{/c/category-1},     q{/t/thread-1},
    q{/search?q=welcome}, q{/search/autocomplete?q=wel},
    q{/health},           q{/health/ready},
    q{/metrics},
);

has app_class => 'GPForum';

sub run {
    my ( $self, @arguments ) = @_;

    my $options = _options(@arguments);
    my $report  = $self->_benchmark_with_options($options);

    _write_baseline( $options->{write_baseline}, $report )
      if defined $options->{write_baseline};

    print $self->format_report( $report, $options->{format} )
      or croak 'failed to write benchmark report';

    return $options->{check} && $report->{status} ne 'ok' ? 1 : 0;
}

sub benchmark_report {
    my ( $self, @arguments ) = @_;

    return $self->_benchmark_with_options( _options(@arguments) );
}

sub format_report {
    my ( $self, $report, $format ) = @_;

    return _report_json($report) if $format eq 'json';

    return _report_text($report);
}

sub _benchmark_with_options {
    my ( $self, $options ) = @_;

    local $ENV{GPFORUM_LOG_LEVEL} = $ENV{GPFORUM_LOG_LEVEL} || 'fatal';

    my $test = Test::Mojo->new( $self->app_class );
    if ( $options->{fixture} ) {
        _install_fixture_services($test);
    }

    my $report = $self->_benchmark( $test, $options );
    _compare_baseline( $report, $options )
      if defined $options->{baseline};

    return $report;
}

sub _benchmark {
    my ( $self, $test, $options ) = @_;

    my @routes = @{ $options->{routes} };
    my @reports;

    for my $route (@routes) {
        push @reports, _route_report( $test, $route, $options );
    }

    return {
        mode       => $options->{fixture} ? 'fixture' : 'configured',
        status     => _overall_status( \@reports ),
        iterations => $options->{iterations},
        warmup     => $options->{warmup},
        routes     => \@reports,
        process    => {
            pid           => $PROCESS_ID,
            memory_rss_kb => _resident_set_kb(),
        },
    };
}

sub _route_report {
    my ( $test, $route, $options ) = @_;

    _warm_route( $test, $route, $options->{warmup} );

    my @latencies;
    my %statuses;
    my $started = time;

    for ( 1 .. $options->{iterations} ) {
        my $sample = _request_sample( $test, $route );
        push @latencies, $sample->{elapsed_ms};
        $statuses{ $sample->{status} }++;
    }

    my $elapsed = time - $started;

    return _summary( $route, \@latencies, \%statuses, $elapsed );
}

sub _warm_route {
    my ( $test, $route, $warmup ) = @_;

    for ( 1 .. $warmup ) {
        _request_sample( $test, $route );
    }

    return;
}

sub _request_sample {
    my ( $test, $route ) = @_;

    my $tx      = $test->ua->build_tx( GET => $route );
    my $started = time;
    my $result  = $test->ua->start($tx);

    return {
        status     => $result->res->code || 0,
        elapsed_ms => ( time - $started ) * $MILLISECONDS,
    };
}

sub _summary {
    my ( $route, $latencies, $statuses, $elapsed ) = @_;

    my @sorted    = sort { $a <=> $b } @{$latencies};
    my $p50       = _percentile( \@sorted, $P50 );
    my $p95       = _percentile( \@sorted, $P95 );
    my $p99       = _percentile( \@sorted, $P99 );
    my $rps       = scalar(@sorted) / _nonzero($elapsed);
    my $threshold = _threshold_for($route);

    return {
        route        => $route,
        status       => _threshold_status( $p95, $p99, $rps, $threshold ),
        requests     => scalar @sorted,
        req_per_sec  => _rounded($rps),
        p50_ms       => _rounded($p50),
        p95_ms       => _rounded($p95),
        p99_ms       => _rounded($p99),
        max_ms       => _rounded( $sorted[-1] || 0 ),
        status_codes => $statuses,
        query_budget => _query_budget($route),
        threshold    => $threshold,
    };
}

sub _report_json {
    my ($report) = @_;

    return encode_json($report) . "\n";
}

sub _report_text {
    my ($report) = @_;

    my $text =
        "mode=$report->{mode} status=$report->{status}"
      . " iterations=$report->{iterations} warmup=$report->{warmup}"
      . " pid=$report->{process}{pid}"
      . q{ memory_rss_kb=}
      . (
        defined $report->{process}{memory_rss_kb}
        ? $report->{process}{memory_rss_kb}
        : 'unknown'
      ) . "\n";

    for my $route ( @{ $report->{routes} } ) {
        $text .= _route_line($route);
    }

    return $text;
}

sub _route_line {
    my ($route) = @_;

    return join q{ },
      'route=' . $route->{route},
      'status=' . $route->{status},
      'requests=' . $route->{requests},
      'req_per_sec=' . $route->{req_per_sec},
      'p50_ms=' . $route->{p50_ms},
      'p95_ms=' . $route->{p95_ms},
      'p99_ms=' . $route->{p99_ms},
      'max_ms=' . $route->{max_ms},
      'threshold=' . _threshold_text( $route->{threshold} ),
      'regression=' . _regression_text( $route->{regression} ),
      'query_budget=' . _query_budget_text( $route->{query_budget} ),
      'statuses=' . _statuses( $route->{status_codes} ),
      "\n";
}

sub _statuses {
    my ($statuses) = @_;

    return join q{,},
      map { $_ . q{:} . $statuses->{$_} } sort keys %{$statuses};
}

sub _query_budget {
    my ($route) = @_;

    my $endpoint_name = _endpoint_name($route);
    my $budget;
    if ( defined $endpoint_name ) {
        $budget =
          GPForum::Service::Operations::QueryBudget->new->budget_for(
            $endpoint_name);
    }

    return $budget;
}

sub _endpoint_name {
    my ($route) = @_;

    return 'search_autocomplete' if $route =~ m{\A /search/autocomplete}msx;
    return 'category_threads'    if $route =~ m{\A /c/}msx;
    return 'thread_view'         if $route =~ m{\A /t/}msx;
    return 'search'              if $route =~ m{\A /search}msx;

    return $ROUTE_ENDPOINT{$route};
}

sub _query_budget_text {
    my ($budget) = @_;

    return 'none' if !$budget;

    return $budget->{endpoint_name} . q{:} . $budget->{max_queries};
}

sub _threshold_for {
    my ($route) = @_;

    my $endpoint_name = _endpoint_name($route);
    my $threshold =
      defined $endpoint_name ? $THRESHOLD_BY_ENDPOINT{$endpoint_name} : undef;
    $threshold ||= {
        p95_ms          => $DEFAULT_P95_LIMIT,
        p99_ms          => $DEFAULT_P99_LIMIT,
        min_req_per_sec => $DEFAULT_MIN_RPS,
    };

    return { %{$threshold} };
}

sub _threshold_status {
    my ( $p95, $p99, $rps, $threshold ) = @_;

    return 'fail'
      if $p95 > $threshold->{p95_ms}
      || $p99 > $threshold->{p99_ms}
      || $rps < $threshold->{min_req_per_sec};

    return 'ok';
}

sub _threshold_text {
    my ($threshold) = @_;

    return join q{,},
      'p95_ms<=' . $threshold->{p95_ms},
      'p99_ms<=' . $threshold->{p99_ms},
      'req_per_sec>=' . $threshold->{min_req_per_sec};
}

sub _overall_status {
    my ($routes) = @_;

    for my $route ( @{$routes} ) {
        return 'fail' if $route->{status} ne 'ok';
    }

    return 'ok';
}

sub _compare_baseline {
    my ( $report, $options ) = @_;

    my $baseline = _read_baseline( $options->{baseline} );
    my %baseline_by_route =
      map { $_->{route} => $_ } @{ $baseline->{routes} || [] };

    for my $route ( @{ $report->{routes} } ) {
        _compare_route_to_baseline(
            $route,
            $baseline_by_route{ $route->{route} },
            $options->{regression_tolerance},
        );
    }

    $report->{baseline} = {
        path                 => $options->{baseline},
        regression_tolerance => $options->{regression_tolerance},
    };
    $report->{status} = _overall_status( $report->{routes} );

    return;
}

sub _compare_route_to_baseline {
    my ( $route, $baseline, $tolerance ) = @_;

    if ( !$baseline ) {
        $route->{regression} = {
            status     => 'missing',
            violations => [
                {
                    metric   => 'route',
                    observed => $route->{route},
                    allowed  => 'present-in-baseline',
                    baseline => undef,
                },
            ],
        };
        $route->{status} = 'fail';
        return;
    }

    my @violations;
    _add_upper_violation( \@violations, $route, $baseline, $tolerance,
        'p95_ms' );
    _add_upper_violation( \@violations, $route, $baseline, $tolerance,
        'p99_ms' );
    _add_lower_violation( \@violations, $route, $baseline, $tolerance,
        'req_per_sec' );

    $route->{regression} = {
        status     => @violations ? 'fail' : 'ok',
        violations => \@violations,
    };
    $route->{status} = 'fail' if @violations;

    return;
}

sub _add_upper_violation {
    my ( $violations, $route, $baseline, $tolerance, $metric ) = @_;

    my $allowed = $baseline->{$metric} * ( 1 + $tolerance );
    return if $route->{$metric} <= $allowed;

    push @{$violations},
      {
        metric   => $metric,
        observed => $route->{$metric},
        allowed  => _rounded($allowed),
        baseline => $baseline->{$metric},
      };

    return;
}

sub _add_lower_violation {
    my ( $violations, $route, $baseline, $tolerance, $metric ) = @_;

    return if !$baseline->{$metric};

    my $allowed = $baseline->{$metric} * ( 1 - $tolerance );
    return if $route->{$metric} >= $allowed;

    push @{$violations},
      {
        metric   => $metric,
        observed => $route->{$metric},
        allowed  => _rounded($allowed),
        baseline => $baseline->{$metric},
      };

    return;
}

sub _regression_text {
    my ($regression) = @_;

    return 'not-checked' if !$regression;
    return $regression->{status};
}

sub _read_baseline {
    my ($path) = @_;

    open my $handle, '<', $path
      or croak "failed to read benchmark baseline $path: $ERRNO";
    local $INPUT_RECORD_SEPARATOR = undef;
    my $json = <$handle>;
    close $handle or croak "failed to close benchmark baseline $path: $ERRNO";

    return decode_json($json);
}

sub _write_baseline {
    my ( $path, $report ) = @_;

    open my $handle, '>', $path
      or croak "failed to write benchmark baseline $path: $ERRNO";
    print {$handle} _report_json($report)
      or croak "failed to write benchmark baseline $path: $ERRNO";
    close $handle or croak "failed to close benchmark baseline $path: $ERRNO";

    return;
}

sub _options {
    my (@arguments) = @_;

    my $options = {
        fixture              => 1,
        check                => 0,
        format               => 'text',
        iterations           => $DEFAULT_ITERATIONS,
        regression_tolerance => 0.25,
        warmup               => $DEFAULT_WARMUP,
        routes               => [],
    };

    while (@arguments) {
        _consume_option( $options, \@arguments );
    }

    if ( !@{ $options->{routes} } ) {
        $options->{routes} = [@DEFAULT_ROUTES];
    }

    return $options;
}

sub _consume_option {
    my ( $options, $arguments ) = @_;

    my $argument = shift @{$arguments};

    my %handler_for = (
        '--fixture'    => sub { $options->{fixture} = 1; },
        '--configured' => sub { $options->{fixture} = 0; },
        '--json'       => sub { $options->{format}  = 'json'; },
        '--check'      => sub { $options->{check}   = 1; },
        '--iterations' => sub {
            $options->{iterations} =
              _positive_integer( shift @{$arguments} );
        },
        '--warmup' => sub {
            $options->{warmup} =
              _non_negative_integer( shift @{$arguments} );
        },
        '--route' => sub {
            push @{ $options->{routes} }, _route( shift @{$arguments} );
        },
        '--baseline' => sub {
            $options->{baseline} = _path( shift @{$arguments} );
        },
        '--write-baseline' => sub {
            $options->{write_baseline} = _path( shift @{$arguments} );
        },
        '--regression-tolerance' => sub {
            $options->{regression_tolerance} =
              _non_negative_number( shift @{$arguments} );
        },
    );

    my $handler = $handler_for{$argument};
    croak _usage() if !$handler;

    $handler->();

    return;
}

sub _install_fixture_services {
    my ($test) = @_;

    my $services = GPForum::Benchmark::FixtureServices->new;
    for my $helper (
        qw(
        gp_category_reader gp_thread_reader gp_home_page_reader
        gp_thread_detail_reader gp_search_service gp_feed_reader
        gp_metrics_snapshot
        )
      )
    {
        $test->app->helper( $helper => sub { return $services; } );
    }

    return;
}

sub _percentile {
    my ( $sorted, $percentile ) = @_;

    return 0 if !@{$sorted};

    my $index = int( ( ( @{$sorted} - 1 ) * $percentile ) / $PERCENT );
    return $sorted->[$index];
}

sub _rounded {
    my ($value) = @_;

    return sprintf '%.3f', $value;
}

sub _nonzero {
    my ($value) = @_;

    return $value > 0 ? $value : $MIN_ELAPSED;
}

sub _positive_integer {
    my ($value) = @_;

    croak _usage()
      if !defined $value || $value !~ /\A [1-9][[:digit:]]* \z/msx;

    return int $value;
}

sub _non_negative_integer {
    my ($value) = @_;

    croak _usage() if !defined $value || $value !~ /\A [[:digit:]]+ \z/msx;

    return int $value;
}

sub _route {
    my ($value) = @_;

    croak _usage() if !defined $value || $value !~ m{\A /}msx;

    return $value;
}

sub _path {
    my ($value) = @_;

    croak _usage() if !defined $value || !length $value;

    return $value;
}

sub _non_negative_number {
    my ($value) = @_;

    croak _usage()
      if !defined $value
      || $value !~
      /\A (?: [[:digit:]]+ (?: [.] [[:digit:]]+ )? | [.] [[:digit:]]+ ) \z/msx;

    return 0 + $value;
}

sub _resident_set_kb {
    open my $process, q{-|}, q{ps}, q{-o}, q{rss=}, q{-p}, $PROCESS_ID
      or return;

    my $rss = <$process>;
    close $process or return;

    return if !defined $rss;
    $rss =~ s/\A \s+//msx;
    $rss =~ s/\s+ \z//msx;

    return $rss =~ /\A [[:digit:]]+ \z/msx ? int $rss : undef;
}

sub _usage {
    return
'Usage: bin/gpforum-benchmark [--fixture|--configured] [--json] [--check] [--iterations N] [--warmup N] [--route /path] [--baseline file] [--write-baseline file] [--regression-tolerance N] ...';
}

1;
