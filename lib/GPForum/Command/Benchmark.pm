# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Benchmark;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json encode_json);
use Mojo::Base -base, -signatures;
use v5.40;
use Test::Mojo;
use Time::HiRes qw(time);

use GPForum::Command::PerformanceSeed;
use GPForum::Command::Usage;
use GPForum::Benchmark::FixtureServices;
use GPForum::Benchmark::Measure qw(
  db_query_text endpoint_name overall_status query_summary regressions
  route_summary sample_route statuses_text
);
use GPForum::Service::Operations::QueryBudget;

our $VERSION = '0.001';

const my $DEFAULT_ITERATIONS => 50;
const my $DEFAULT_WARMUP     => 5;
const my $MILLISECONDS       => 1_000;
const my @DEFAULT_ROUTES => (
    q{/},                 q{/categories},
    q{/c/category-1},     q{/t/thread-1},
    q{/search?q=welcome}, q{/search/autocomplete?q=wel},
    q{/health},           q{/health/ready},
    q{/metrics},
);
const my @SEEDED_ROUTES => (
    q{/},
    q{/categories},
    q{/c/018f1001-0001-7000-8000-000000000001},
    q{/t/018f1004-0001-7000-8000-000000000001},
    q{/search?q=performance},
    q{/search/autocomplete?q=per},
    q{/health},
    q{/health/ready},
    q{/metrics},
);
const my $ROUTE => qr{\A /}msx;
const my $PATH  => qr/./msx;
const my %SWITCH_OPTION => (
    '--check'      => { check   => 1 },
    '--configured' => { fixture => 0 },
    '--fixture'    => { fixture => 1 },
    '--json'       => { format  => 'json' },
);

# Each option taking a number: the option it sets and the number's shape.
const my %NUMBER_OPTION => (
    '--iterations'           => [ iterations => 'positive_integer' ],
    '--regression-tolerance' =>
      [ regression_tolerance => 'non_negative_number' ],
    '--warmup' => [ warmup => 'non_negative_integer' ],
);

has app_class => 'GPForum';

# --help is answered before anything is parsed, and a parse failure becomes a
# usage error rather than an uncaught croak: this used to exit 255 with
# " at FILE line N." glued to the help text.
sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $status;
    try {
        $status = $self->_run(@arguments);
    }
    catch ($error) {
        return GPForum::Command::Usage->error(
            GPForum::Command::Usage->trimmed($error), _usage() );
    };

    return $status;
}

sub _run ( $self, @arguments ) {
    my $options = _options(@arguments);
    my $report  = $self->_benchmark_with_options($options);

    if ( defined $options->{write_baseline} ) {
        _write_baseline( $options->{write_baseline}, $report );
    }

    print $self->format_report( $report, $options->{format} )
      or croak 'failed to write benchmark report';

    return $options->{check} && $report->{status} ne 'ok' ? 1 : 0;
}

sub benchmark_report ( $self, @arguments ) {
    return $self->_benchmark_with_options( _options(@arguments) );
}

sub format_report ( $self, $report, $format ) {
    return _report_json($report) if $format eq 'json';

    return _report_text($report);
}

sub _benchmark_with_options ( $self, $options ) {
    local $ENV{GPFORUM_LOG_LEVEL} = $ENV{GPFORUM_LOG_LEVEL} || 'fatal';

    my $test = Test::Mojo->new( $self->app_class );
    if ( $options->{fixture} ) {
        _install_fixture_services($test);
    }

    my @reports =
      map { _route_report( $test, $_, $options ) } @{ $options->{routes} };
    my $report = {
        mode       => $options->{fixture} ? 'fixture' : 'configured',
        status     => overall_status( \@reports ),
        iterations => $options->{iterations},
        warmup     => $options->{warmup},
        routes     => \@reports,
        dataset    => {
            profile       => $options->{profile},
            seeded_routes => $options->{profile} eq 'fixture' ? 0 : 1,
        },
        process => {
            pid           => $PROCESS_ID,
            worker_count  => $ENV{GPFORUM_WEB_PROCESSES} || 'configured',
            memory_rss_kb => _resident_set_kb(),
        },
    };
    if ( defined $options->{baseline} ) {
        _compare_baseline( $report, $options );
    }

    return $report;
}

sub _route_report ( $test, $route, $options ) {
    for ( 1 .. $options->{warmup} ) {
        _request_sample( $test, $route );
    }
    my $samples = sample_route( $options->{iterations},
        sub { return _request_sample( $test, $route ); } );

    my $endpoint_name = endpoint_name($route);
    my $budget =
      defined $endpoint_name
      ? GPForum::Service::Operations::QueryBudget->new->budget_for(
        $endpoint_name)
      : undef;
    my $db_queries = query_summary( $samples->{observations} );
    $db_queries->{budget_status} //=
      _observed_budget_status( $db_queries, $budget );

    return {
        %{ route_summary( $route, $samples, $db_queries ) },
        query_budget => $budget,
    };
}

sub _request_sample ( $test, $route ) {
    my $tx         = $test->ua->build_tx( GET => $route );
    my $started    = time;
    my $result     = $test->ua->start($tx);
    my $elapsed_ms = ( time - $started ) * $MILLISECONDS;

    # The queries the request ran, when the application counts them and the
    # count is this request's.
    my $stats;
    try {
        $stats = $test->app->build_controller->gp_db_query_stats;
    }
    catch ($error) {

        # An application without the helper counts nothing.
        $stats = undef;
    };
    my $last_request = $stats ? $stats->last_request : undef;

    return {
        status         => $result->res->code || 0,
        elapsed_ms     => $elapsed_ms,
        db_query_stats => $last_request
          && $last_request->{attached} ? $last_request : undef,
    };
}

sub _report_json ($report) {
    return encode_json($report) . "\n";
}

sub _report_text ($report) {
    my $text =
        "mode=$report->{mode} status=$report->{status}"
      . " iterations=$report->{iterations} warmup=$report->{warmup}"
      . " dataset_profile=$report->{dataset}{profile}"
      . " pid=$report->{process}{pid}"
      . " worker_count=$report->{process}{worker_count}"
      . q{ memory_rss_kb=}
      . (
        defined $report->{process}{memory_rss_kb}
        ? $report->{process}{memory_rss_kb}
        : 'unknown'
      ) . "\n";

    for my $route ( @{ $report->{routes} } ) {
        my ( $threshold, $regression, $budget ) =
          @{$route}{qw(threshold regression query_budget)};
        $text .= join q{ },
          'route=' . $route->{route},
          'status=' . $route->{status},
          'requests=' . $route->{requests},
          'req_per_sec=' . $route->{req_per_sec},
          'p50_ms=' . $route->{p50_ms},
          'p95_ms=' . $route->{p95_ms},
          'p99_ms=' . $route->{p99_ms}, 'max_ms=' . $route->{max_ms},
          'threshold='
          . join( q{,},
            'p95_ms<=' . $threshold->{p95_ms},
            'p99_ms<=' . $threshold->{p99_ms},
            'req_per_sec>=' . $threshold->{min_req_per_sec} ),
          'regression='
          . ( $regression ? $regression->{status} : 'not-checked' ),
          'query_budget='
          . (
              $budget
            ? $budget->{endpoint_name} . q{:} . $budget->{max_queries}
            : 'none'
          ),
          'db_queries=' . db_query_text( $route->{db_queries} ),
          'statuses=' . statuses_text( $route->{status_codes} ),
          "\n";
    }

    return $text;
}

sub _observed_budget_status ( $db_queries, $budget ) {
    return 'none' if !$budget;
    return 'fail' if $db_queries->{max_queries} > $budget->{max_queries};
    return 'fail'
      if $db_queries->{max_transactions} > $budget->{max_transactions};

    return 'ok';
}

sub _compare_baseline ( $report, $options ) {
    my $baseline = _read_baseline( $options->{baseline} );
    my %baseline_by_route =
      map { $_->{route} => $_ } @{ $baseline->{routes} || [] };

    for my $route ( @{ $report->{routes} } ) {
        my $baseline_route = $baseline_by_route{ $route->{route} };
        if ( !$baseline_route ) {
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
            next;
        }

        my @violations = regressions( $route, $baseline_route,
            $options->{regression_tolerance} );
        $route->{regression} = {
            status     => @violations ? 'fail' : 'ok',
            violations => \@violations,
        };
        if (@violations) {
            $route->{status} = 'fail';
        }
    }

    $report->{baseline} = {
        path                 => $options->{baseline},
        regression_tolerance => $options->{regression_tolerance},
    };
    $report->{status} = overall_status( $report->{routes} );

    return;
}

sub _read_baseline ($path) {
    open my $handle, '<', $path
      or croak "failed to read benchmark baseline $path: $ERRNO";
    local $INPUT_RECORD_SEPARATOR = undef;
    my $json = <$handle>;
    close $handle or croak "failed to close benchmark baseline $path: $ERRNO";

    return decode_json($json);
}

sub _write_baseline ( $path, $report ) {
    open my $handle, '>', $path
      or croak "failed to write benchmark baseline $path: $ERRNO";
    print {$handle} _report_json($report)
      or croak "failed to write benchmark baseline $path: $ERRNO";
    close $handle or croak "failed to close benchmark baseline $path: $ERRNO";

    return;
}

sub _options (@arguments) {
    my $usage   = _usage();
    my $options = GPForum::Command::Usage->parse_options(
        \@arguments,
        {
            fixture              => 1,
            check                => 0,
            format               => 'text',
            iterations           => $DEFAULT_ITERATIONS,
            regression_tolerance => 0.25,
            profile              => 'fixture',
            warmup               => $DEFAULT_WARMUP,
            routes               => [],
        },
        {
            usage    => $usage,
            switches => \%SWITCH_OPTION,
            numbers  => \%NUMBER_OPTION,
            values   => {
                '--baseline' => sub ( $options, $value ) {
                    $options->{baseline} =
                      GPForum::Command::Usage->option_value( $value, $PATH,
                        $usage );
                },
                '--profile' => sub ( $options, $value ) {
                    $options->{profile} =
                      GPForum::Command::Usage->option_choice(
                        $value,
                        [
                            'fixture',
                            GPForum::Command::PerformanceSeed->profiles
                        ],
                        $usage
                      );
                },
                '--route' => sub ( $options, $value ) {
                    push @{ $options->{routes} },
                      GPForum::Command::Usage->option_value( $value, $ROUTE,
                        $usage );
                },
                '--write-baseline' => sub ( $options, $value ) {
                    $options->{write_baseline} =
                      GPForum::Command::Usage->option_value( $value, $PATH,
                        $usage );
                },
            },
        },
    );

    if ( !@{ $options->{routes} } ) {
        $options->{routes} =
          $options->{profile} eq 'fixture'
          ? [@DEFAULT_ROUTES]
          : [@SEEDED_ROUTES];
    }

    return $options;
}

sub _install_fixture_services ($test) {
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

sub _resident_set_kb {
    open my $process, q{-|}, q{ps}, q{-o}, q{rss=}, q{-p}, $PROCESS_ID
      or return undef;

    my $rss = <$process>;
    close $process or return undef;

    return undef if !defined $rss;
    $rss =~ s/\A \s+//msx;
    $rss =~ s/\s+ \z//msx;

    return $rss =~ /\A [[:digit:]]+ \z/msx ? int $rss : undef;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return
'Usage: bin/gpforum-benchmark [--fixture|--configured] [--json] [--check] [--profile fixture|small|medium|hot-thread] [--iterations N] [--warmup N] [--route /path] [--baseline file] [--write-baseline file] [--regression-tolerance N] ...';
}

1;
