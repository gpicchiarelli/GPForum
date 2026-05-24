package GPForum::Command::HypnotoadBenchmark;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Cwd        qw(abs_path);
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base;
use Mojo::UserAgent;
use POSIX       qw(setsid WNOHANG);
use Time::HiRes qw(sleep time);

use GPForum::Command::Benchmark;
use GPForum::Command::PerformanceSeed;
use GPForum::Config;
use GPForum::Schema;

our $VERSION = '0.001';

const my $DEFAULT_ITERATIONS           => 20;
const my $DEFAULT_WARMUP               => 3;
const my $DEFAULT_WORKERS              => 2;
const my $DEFAULT_STARTUP_TIMEOUT      => 15;
const my $DEFAULT_REGRESSION_TOLERANCE => 5;
const my $MILLISECONDS                 => 1_000;
const my $PERCENT                      => 100;
const my $P50                          => 50;
const my $P95                          => 95;
const my $P99                          => 99;
const my $MIN_ELAPSED                  => 0.000_001;
const my $HTTP_OK_MIN                  => 200;
const my $HTTP_OK_MAX                  => 399;
const my $DEFAULT_P95_LIMIT            => 1_000;
const my $DEFAULT_P99_LIMIT            => 2_000;
const my $DEFAULT_MIN_RPS              => 1;
const my $READY_SLEEP                  => 0.1;
const my $STOP_SLEEP                   => 0.1;
const my $STOP_ATTEMPTS                => 50;
const my $KILL_ATTEMPTS                => 20;
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
const my @SEEDED_ROUTES => (
    q{/},
    q{/categories},
    q{/c/018f1001-0001-7000-8000-000000000001},
    q{/t/018f1004-0001-7000-8000-000000000001},
    q{/search?q=performance},
    q{/search/autocomplete?q=per},
    q{/health/live},
    q{/health/ready},
    q{/metrics},
);

sub run {
    my ( $self, @arguments ) = @_;

    my $options = _options(@arguments);
    my $report  = $self->benchmark_report($options);

    print $self->format_report( $report, $options->{format} )
      or croak 'failed to write hypnotoad benchmark report';

    return $options->{check} && $report->{status} ne 'ok' ? 1 : 0;
}

sub benchmark_report {
    my ( $self, $options ) = @_;

    return _dry_run_report($options) if $options->{dry_run};

    _assert_database_available();
    _seed_profile($options) if $options->{seed};

    my $in_process =
      $options->{compare_in_process}
      ? _in_process_report($options)
      : undef;

    my $runtime = _start_hypnotoad($options);
    my $report;
    my $error;
    my $ok = eval {
        _wait_until_ready($runtime);
        $report = _runtime_report( $runtime, $options, $in_process );
        return 1;
    };
    if ( !$ok ) {
        $error = $EVAL_ERROR || 'unknown hypnotoad benchmark error';
    }

    _stop_hypnotoad($runtime);
    croak $error if defined $error && length $error;

    return $report;
}

sub format_report {
    my ( $self, $report, $format ) = @_;

    return encode_json($report) . "\n" if $format eq 'json';

    return _text_report($report);
}

sub _runtime_report {
    my ( $runtime, $options, $in_process ) = @_;

    my @route_reports;
    for my $route ( @{ $options->{routes} } ) {
        my $baseline = _route_from_report( $in_process, $route );
        push @route_reports,
          _route_report( $runtime, $route, $options, $baseline );
    }

    return {
        mode       => 'hypnotoad',
        status     => _overall_status( \@route_reports ),
        iterations => $options->{iterations},
        warmup     => $options->{warmup},
        routes     => \@route_reports,
        dataset    => { profile => $options->{profile} },
        runtime    => _runtime_metadata( $runtime, $options ),
        comparison => {
            in_process_enabled   => $in_process ? 1 : 0,
            regression_tolerance => $options->{regression_tolerance},
            in_process           => $in_process,
        },
    };
}

sub _route_report {
    my ( $runtime, $route, $options, $baseline ) = @_;

    _warm_route( $runtime, $route, $options->{warmup} );

    my @latencies;
    my @observations;
    my %statuses;
    my $started = time;
    for ( 1 .. $options->{iterations} ) {
        my $sample = _request_sample( $runtime, $route );
        push @latencies,    $sample->{elapsed_ms};
        push @observations, $sample->{db_query_stats};
        $statuses{ $sample->{status} }++;
    }

    my $elapsed = time - $started;
    my $summary =
      _summary( $route, \@latencies, \%statuses, $elapsed, \@observations );
    my $comparison =
      _compare_route( $summary, $baseline, $options->{regression_tolerance} );

    $summary->{comparison} = $comparison if $comparison;
    $summary->{status}     = 'fail'
      if $comparison && $comparison->{status} eq 'fail';

    return $summary;
}

sub _warm_route {
    my ( $runtime, $route, $warmup ) = @_;

    for ( 1 .. $warmup ) {
        _request_sample( $runtime, $route );
    }

    return;
}

sub _request_sample {
    my ( $runtime, $route ) = @_;

    my $started = time;
    my $tx      = $runtime->{ua}->get( $runtime->{base_url} . $route );
    my $elapsed = ( time - $started ) * $MILLISECONDS;
    my $res     = $tx->result;

    return {
        status         => $res->code || 0,
        elapsed_ms     => $elapsed,
        db_query_stats => _header_query_stats($res),
    };
}

sub _header_query_stats {
    my ($res) = @_;

    my $headers = $res->headers;

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

sub _header_integer {
    my ( $headers, $name ) = @_;

    my $value = $headers->header($name);
    return 0 if !defined $value || $value !~ /\A [[:digit:]]+ \z/msx;

    return int $value;
}

sub _summary {
    my ( $route, $latencies, $statuses, $elapsed, $observations ) = @_;

    my @sorted     = sort { $a <=> $b } @{$latencies};
    my $p50        = _percentile( \@sorted, $P50 );
    my $p95        = _percentile( \@sorted, $P95 );
    my $p99        = _percentile( \@sorted, $P99 );
    my $rps        = scalar(@sorted) / _nonzero($elapsed);
    my $threshold  = _threshold_for($route);
    my $db_queries = _db_query_summary($observations);

    return {
        route  => $route,
        status =>
          _route_status( $p95, $p99, $rps, $threshold, $statuses, $db_queries ),
        requests     => scalar @sorted,
        req_per_sec  => _rounded($rps),
        p50_ms       => _rounded($p50),
        p95_ms       => _rounded($p95),
        p99_ms       => _rounded($p99),
        max_ms       => _rounded( $sorted[-1] || 0 ),
        status_codes => $statuses,
        db_queries   => $db_queries,
        query_budget => _endpoint_name($route),
        threshold    => $threshold,
        error_rate   => _error_rate($statuses),
    };
}

sub _db_query_summary {
    my ($observations) = @_;

    return { observed => 0, budget_status => 'not-observed' }
      if !@{$observations};

    my @queries      = map { $_->{queries}      || 0 } @{$observations};
    my @transactions = map { $_->{transactions} || 0 } @{$observations};
    my @duplicates =
      map { $_->{duplicate_queries} || 0 } @{$observations};
    my %budget_status;
    for my $observation ( @{$observations} ) {
        $budget_status{ $observation->{query_budget_status} || 'none' } = 1;
    }
    my $status =
        exists $budget_status{fail} ? 'fail'
      : exists $budget_status{ok}   ? 'ok'
      :                               'none';

    return {
        observed              => 1,
        samples               => scalar @{$observations},
        max_queries           => _max(@queries),
        avg_queries           => _rounded( _average(@queries) ),
        max_transactions      => _max(@transactions),
        max_duplicate_queries => _max(@duplicates),
        budget_status         => $status,
    };
}

sub _route_status {
    my ( $p95, $p99, $rps, $threshold, $statuses, $db_queries ) = @_;

    return 'fail'
      if $p95 > $threshold->{p95_ms}
      || $p99 > $threshold->{p99_ms}
      || $rps < $threshold->{min_req_per_sec};
    return 'fail' if _error_count($statuses) > 0;
    return 'fail'
      if $db_queries->{observed} && $db_queries->{budget_status} eq 'fail';
    return 'fail'
      if $db_queries->{observed}
      && $db_queries->{budget_status} ne 'none'
      && $db_queries->{max_duplicate_queries} > 0;

    return 'ok';
}

sub _compare_route {
    my ( $route, $baseline, $tolerance ) = @_;

    return if !$baseline;

    my @violations;
    _upper_regression( \@violations, $route, $baseline, $tolerance, 'p95_ms' );
    _upper_regression( \@violations, $route, $baseline, $tolerance, 'p99_ms' );
    _lower_regression( \@violations, $route, $baseline, $tolerance,
        'req_per_sec' );

    return {
        status   => @violations ? 'fail' : 'ok',
        baseline => {
            p50_ms      => $baseline->{p50_ms},
            p95_ms      => $baseline->{p95_ms},
            p99_ms      => $baseline->{p99_ms},
            req_per_sec => $baseline->{req_per_sec},
        },
        violations => \@violations,
    };
}

sub _upper_regression {
    my ( $violations, $route, $baseline, $tolerance, $metric ) = @_;

    my $allowed = $baseline->{$metric} * ( 1 + $tolerance );
    return if $route->{$metric} <= $allowed;

    push @{$violations},
      {
        metric   => $metric,
        observed => $route->{$metric},
        baseline => $baseline->{$metric},
        allowed  => _rounded($allowed),
      };

    return;
}

sub _lower_regression {
    my ( $violations, $route, $baseline, $tolerance, $metric ) = @_;

    return if !$baseline->{$metric};

    my $allowed = $baseline->{$metric} * ( 1 - $tolerance );
    return if $route->{$metric} >= $allowed;

    push @{$violations},
      {
        metric   => $metric,
        observed => $route->{$metric},
        baseline => $baseline->{$metric},
        allowed  => _rounded($allowed),
      };

    return;
}

sub _in_process_report {
    my ($options) = @_;

    return GPForum::Command::Benchmark->new->benchmark_report(
        '--configured',
        '--profile',
        $options->{profile},
        '--iterations',
        $options->{iterations},
        '--warmup',
        $options->{warmup},
        map { ( '--route', $_ ) } @{ $options->{routes} },
    );
}

sub _route_from_report {
    my ( $report, $route ) = @_;

    return if !$report;
    for my $candidate ( @{ $report->{routes} || [] } ) {
        return $candidate if $candidate->{route} eq $route;
    }

    return;
}

sub _start_hypnotoad {
    my ($options) = @_;

    my $directory   = tempdir( 'gpforum-hypnotoad-XXXXXX', TMPDIR => 1 );
    my $port        = $options->{port} || _free_port();
    my $pid_file    = "$directory/hypnotoad.pid";
    my $log_file    = "$directory/hypnotoad.log";
    my $app_file    = "$directory/gpforum-hypnotoad-app.pl";
    my $base_url    = "http://127.0.0.1:$port";
    my %environment = _runtime_environment( $options, $port, $pid_file );

    _write_hypnotoad_app($app_file);

    my $pid = fork;
    croak 'failed to fork hypnotoad benchmark process' if !defined $pid;

    if ( $pid == 0 ) {
        setsid or die 'failed to create hypnotoad process session';
        _redirect_child_output($log_file);
        local %ENV = ( %ENV, %environment );
        exec 'carton', 'exec', '--', 'hypnotoad', '-f', $app_file;
        die 'failed to exec hypnotoad';
    }

    return {
        process_pid => $pid,
        pid_file    => $pid_file,
        log_file    => $log_file,
        app_file    => $app_file,
        base_url    => $base_url,
        port        => $port,
        environment => \%environment,
        ua          => Mojo::UserAgent->new( request_timeout => 5 ),
    };
}

sub _write_hypnotoad_app {
    my ($app_file) = @_;

    my $library = abs_path('lib')
      or croak 'failed to resolve GPForum lib directory';
    open my $handle, '>', $app_file
      or croak "failed to write benchmark hypnotoad app $app_file";
    print {$handle} <<"APP" or croak "failed to write $app_file";
use strict;
use warnings;
use lib '$library';
use GPForum;
GPForum->new;
APP
    close $handle or croak "failed to close $app_file";

    return;
}

sub _runtime_environment {
    my ( $options, $port, $pid_file ) = @_;

    return (
        GPFORUM_LOG_LEVEL                  => 'fatal',
        GPFORUM_BENCHMARK_QUERY_HEADERS    => 1,
        GPFORUM_RUNTIME_LISTEN             => "http://127.0.0.1:$port",
        GPFORUM_RUNTIME_PID_FILE           => $pid_file,
        GPFORUM_RUNTIME_WORKER_POLICY      => 'configured',
        GPFORUM_RUNTIME_PROXY              => 0,
        GPFORUM_RUNTIME_BACKLOG            => $options->{backlog},
        GPFORUM_RUNTIME_CLIENTS            => $options->{clients},
        GPFORUM_RUNTIME_REQUESTS           => $options->{accepts},
        GPFORUM_RUNTIME_KEEP_ALIVE_TIMEOUT => $options->{keep_alive},
        GPFORUM_RUNTIME_INACTIVITY_TIMEOUT => $options->{inactivity},
        GPFORUM_RUNTIME_GRACEFUL_TIMEOUT   => $options->{graceful},
        GPFORUM_WEB_PROCESSES              => $options->{workers},
    );
}

sub _redirect_child_output {
    my ($log_file) = @_;

    open STDOUT, '>>', $log_file or die "failed to open $log_file";
    open STDERR, '>>', $log_file or die "failed to open $log_file";

    return;
}

sub _wait_until_ready {
    my ($runtime) = @_;

    my $deadline = time + $DEFAULT_STARTUP_TIMEOUT;
    if ( exists $runtime->{environment}{GPFORUM_STARTUP_TIMEOUT} ) {
        $deadline = time + $runtime->{environment}{GPFORUM_STARTUP_TIMEOUT};
    }

    while ( time < $deadline ) {
        my $ok = eval {
            my $tx =
              $runtime->{ua}->get( $runtime->{base_url} . '/health/live' );
            return ( $tx->result->code || 0 ) == 200 ? 1 : 0;
        };
        return 1 if $ok;
        sleep $READY_SLEEP;
    }

    croak 'hypnotoad did not become ready; see ' . $runtime->{log_file};
}

sub _stop_hypnotoad {
    my ($runtime) = @_;

    return if !$runtime;

    my $pid = $runtime->{process_pid};
    my %environment =
      %{ $runtime->{environment} || {} };
    local %ENV = ( %ENV, %environment );

    _run_hypnotoad_stop($runtime);
    _wait_for_exit($pid) and return;

    kill 'TERM', -$pid if $pid;
    _wait_for_exit($pid) and return;

    kill 'KILL', -$pid if $pid;
    for ( 1 .. $KILL_ATTEMPTS ) {
        return if waitpid( $pid, WNOHANG ) == $pid;
        sleep $STOP_SLEEP;
    }

    unlink $runtime->{pid_file} if -e $runtime->{pid_file};

    return;
}

sub _run_hypnotoad_stop {
    my ($runtime) = @_;

    my $pid = fork;
    return if !defined $pid;
    if ( $pid == 0 ) {
        _redirect_child_output( $runtime->{log_file} );
        local %ENV = ( %ENV, %{ $runtime->{environment} || {} } );
        exec 'carton', 'exec', '--', 'hypnotoad', '-s', $runtime->{app_file};
        die 'failed to exec hypnotoad stop';
    }

    waitpid $pid, 0;

    return;
}

sub _wait_for_exit {
    my ($pid) = @_;

    return 1 if !$pid;
    for ( 1 .. $STOP_ATTEMPTS ) {
        return 1 if waitpid( $pid, WNOHANG ) == $pid;
        sleep $STOP_SLEEP;
    }

    return 0;
}

sub _runtime_metadata {
    my ( $runtime, $options ) = @_;

    my $master_pid = _read_pid_file( $runtime->{pid_file} );

    return {
        base_url            => $runtime->{base_url},
        port                => $runtime->{port},
        workers_requested   => $options->{workers},
        master_pid          => $master_pid,
        foreground_pid      => $runtime->{process_pid},
        worker_pids         => _worker_pids($master_pid),
        app_file            => $runtime->{app_file},
        pid_file            => $runtime->{pid_file},
        log_file            => $runtime->{log_file},
        perl_version        => "$PERL_VERSION",
        mojolicious_version =>
          eval { require Mojolicious; return $Mojolicious::VERSION; }
          || 'unknown',
        git_commit => _git_commit(),
        database   => { dsn => _redacted_dsn() },
        config     => {
            accepts    => $options->{accepts},
            keep_alive => $options->{keep_alive},
            backlog    => $options->{backlog},
            proxy      => 0,
        },
    };
}

sub _read_pid_file {
    my ($pid_file) = @_;

    return if !$pid_file || !-e $pid_file;

    open my $handle, '<', $pid_file or return;
    my $pid = <$handle>;
    close $handle or return;

    return if !defined $pid;
    $pid =~ s/\A \s+//msx;
    $pid =~ s/\s+ \z//msx;

    return $pid =~ /\A [[:digit:]]+ \z/msx ? int $pid : undef;
}

sub _worker_pids {
    my ($master_pid) = @_;

    return [] if !$master_pid;

    open my $processes, q{-|}, 'ps', '-axo', 'pid=,ppid=,command='
      or return [];
    my @workers;
    while ( my $line = <$processes> ) {
        next
          if $line !~ /\A \s* ([[:digit:]]+) \s+ ([[:digit:]]+) \s+ (.+) \z/msx;
        my ( $pid, $parent, $command ) = ( int $1, int $2, $3 );
        next if $parent != $master_pid;
        next if $command !~ /hypnotoad|gpforum/msx;
        push @workers, $pid;
    }
    close $processes or return \@workers;

    return \@workers;
}

sub _seed_profile {
    my ($options) = @_;

    GPForum::Command::PerformanceSeed->new->seed(
        {
            profile => $options->{profile},
            users => $options->{profile} eq 'medium' ? 25
            : $options->{profile} eq 'hot-thread' ? 10
            : 5,
            categories => $options->{profile} eq 'medium' ? 8 : 3,
            threads => $options->{profile} eq 'medium' ? 120
            : $options->{profile} eq 'hot-thread' ? 30
            : 12,
            posts_per_thread => $options->{profile} eq 'medium' ? 15
            : $options->{profile} eq 'hot-thread' ? 120
            : 8,
            dry_run => 0,
            format  => 'text',
        }
    );

    return;
}

sub _assert_database_available {
    my $config = GPForum::Config->from_environment;
    croak 'script/bench-hypnotoad requires GPFORUM_DATABASE_DSN'
      if !defined $config->database_dsn || !length $config->database_dsn;

    my $schema = GPForum::Schema->connect_from_config($config);
    $schema->storage->dbh->selectrow_array('SELECT 1');

    return;
}

sub _dry_run_report {
    my ($options) = @_;

    return {
        mode       => 'hypnotoad',
        status     => 'dry-run',
        iterations => $options->{iterations},
        warmup     => $options->{warmup},
        dataset    => { profile => $options->{profile} },
        routes     => $options->{routes},
        runtime    => {
            workers_requested => $options->{workers},
            port              => $options->{port} || 'auto',
            database          => { dsn => _redacted_dsn() },
        },
        comparison => {
            in_process_enabled   => $options->{compare_in_process} ? 1 : 0,
            regression_tolerance => $options->{regression_tolerance},
        },
    };
}

sub _text_report {
    my ($report) = @_;

    my $text =
        "mode=$report->{mode} status=$report->{status}"
      . " iterations=$report->{iterations} warmup=$report->{warmup}"
      . " dataset_profile=$report->{dataset}{profile}";
    if ( $report->{runtime} ) {
        $text .=
            " workers=$report->{runtime}{workers_requested}"
          . " master_pid="
          . ( $report->{runtime}{master_pid} || 'unknown' )
          . " worker_pids="
          . _list_text( $report->{runtime}{worker_pids} || [] );
    }
    $text .= "\n";

    for my $route ( @{ $report->{routes} || [] } ) {
        next if ref $route ne 'HASH';
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
      'error_rate=' . $route->{error_rate},
      'db_queries=' . _db_query_text( $route->{db_queries} ),
      'comparison=' . _comparison_text( $route->{comparison} ),
      'statuses=' . _statuses( $route->{status_codes} ),
      "\n";
}

sub _db_query_text {
    my ($summary) = @_;

    return 'not-observed' if !$summary || !$summary->{observed};

    return join q{,},
      'max=' . $summary->{max_queries},
      'avg=' . $summary->{avg_queries},
      'transactions=' . $summary->{max_transactions},
      'duplicates=' . $summary->{max_duplicate_queries},
      'budget=' . $summary->{budget_status};
}

sub _comparison_text {
    my ($comparison) = @_;

    return 'not-checked' if !$comparison;

    return $comparison->{status};
}

sub _statuses {
    my ($statuses) = @_;

    return join q{,},
      map { $_ . q{:} . $statuses->{$_} } sort keys %{$statuses};
}

sub _overall_status {
    my ($routes) = @_;

    for my $route ( @{$routes} ) {
        return 'fail' if $route->{status} ne 'ok';
    }

    return 'ok';
}

sub _error_count {
    my ($statuses) = @_;

    my $count = 0;
    for my $status ( keys %{$statuses} ) {
        next if $status >= $HTTP_OK_MIN && $status <= $HTTP_OK_MAX;
        $count += $statuses->{$status};
    }

    return $count;
}

sub _error_rate {
    my ($statuses) = @_;

    my $total = 0;
    for my $status ( keys %{$statuses} ) {
        $total += $statuses->{$status};
    }

    return _rounded( _error_count($statuses) / _nonzero($total) );
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

sub _endpoint_name {
    my ($route) = @_;

    return 'search_autocomplete' if $route =~ m{\A /search/autocomplete}msx;
    return 'category_threads'    if $route =~ m{\A /c/}msx;
    return 'thread_view'         if $route =~ m{\A /t/}msx;
    return 'search'              if $route =~ m{\A /search}msx;

    return $ROUTE_ENDPOINT{$route};
}

sub _options {
    my (@arguments) = @_;

    my $options = {
        check                => 0,
        compare_in_process   => 1,
        dry_run              => 0,
        format               => 'text',
        iterations           => $DEFAULT_ITERATIONS,
        profile              => 'small',
        regression_tolerance => $DEFAULT_REGRESSION_TOLERANCE,
        routes               => [],
        seed                 => 0,
        warmup               => $DEFAULT_WARMUP,
        workers              => $DEFAULT_WORKERS,
        accepts              => 100,
        backlog              => 128,
        clients              => 100,
        graceful             => 10,
        inactivity           => 30,
        keep_alive           => 5,
        port                 => undef,
    };

    while (@arguments) {
        _consume_option( $options, \@arguments );
    }
    if ( !@{ $options->{routes} } ) {
        $options->{routes} = [@SEEDED_ROUTES];
    }

    return $options;
}

sub _consume_option {
    my ( $options, $arguments ) = @_;

    my $argument    = shift @{$arguments};
    my %handler_for = (
        '--accepts' => sub {
            $options->{accepts} = _positive_integer( shift @{$arguments} );
        },
        '--backlog' => sub {
            $options->{backlog} = _positive_integer( shift @{$arguments} );
        },
        '--check'   => sub { $options->{check} = 1; },
        '--clients' => sub {
            $options->{clients} = _positive_integer( shift @{$arguments} );
        },
        '--dry-run'          => sub { $options->{dry_run} = 1; },
        '--graceful-timeout' => sub {
            $options->{graceful} = _positive_integer( shift @{$arguments} );
        },
        '--iterations' => sub {
            $options->{iterations} =
              _positive_integer( shift @{$arguments} );
        },
        '--json'       => sub { $options->{format} = 'json'; },
        '--keep-alive' => sub {
            $options->{keep_alive} = _positive_integer( shift @{$arguments} );
        },
        '--no-compare' => sub { $options->{compare_in_process} = 0; },
        '--port'       => sub {
            $options->{port} = _positive_integer( shift @{$arguments} );
        },
        '--profile' => sub {
            $options->{profile} = _profile( shift @{$arguments} );
        },
        '--regression-tolerance' => sub {
            $options->{regression_tolerance} =
              _non_negative_number( shift @{$arguments} );
        },
        '--route' => sub {
            push @{ $options->{routes} }, _route( shift @{$arguments} );
        },
        '--seed'   => sub { $options->{seed} = 1; },
        '--warmup' => sub {
            $options->{warmup} =
              _non_negative_integer( shift @{$arguments} );
        },
        '--workers' => sub {
            $options->{workers} = _positive_integer( shift @{$arguments} );
        },
    );

    my $handler = $handler_for{$argument};
    croak _usage() if !$handler;
    $handler->();

    return;
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

sub _non_negative_number {
    my ($value) = @_;

    croak _usage()
      if !defined $value
      || $value !~
      /\A (?: [[:digit:]]+ (?: [.] [[:digit:]]+ )? | [.] [[:digit:]]+ ) \z/msx;

    return 0 + $value;
}

sub _route {
    my ($value) = @_;

    croak _usage() if !defined $value || $value !~ m{\A /}msx;

    return $value;
}

sub _profile {
    my ($value) = @_;

    croak _usage()
      if !defined $value
      || ( $value ne 'small'
        && $value ne 'medium'
        && $value ne 'hot-thread' );

    return $value;
}

sub _percentile {
    my ( $sorted, $percentile ) = @_;

    return 0 if !@{$sorted};

    my $index = int( ( ( @{$sorted} - 1 ) * $percentile ) / $PERCENT );
    return $sorted->[$index];
}

sub _max {
    my (@values) = @_;

    my $max = 0;
    for my $value (@values) {
        $max = $value if $value > $max;
    }

    return $max;
}

sub _average {
    my (@values) = @_;

    return 0 if !@values;

    my $sum = 0;
    for my $value (@values) {
        $sum += $value;
    }

    return $sum / scalar @values;
}

sub _rounded {
    my ($value) = @_;

    return sprintf '%.3f', $value;
}

sub _nonzero {
    my ($value) = @_;

    return $value > 0 ? $value : $MIN_ELAPSED;
}

sub _free_port {
    my $socket = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
    ) or croak 'failed to allocate a local benchmark port';

    my $port = $socket->sockport;
    close $socket or croak 'failed to close benchmark port probe socket';

    return $port;
}

sub _git_commit {
    open my $git, q{-|}, qw(git rev-parse --short HEAD)
      or return 'unknown';
    my $commit = <$git>;
    close $git or return 'unknown';
    chomp $commit if defined $commit;

    return defined $commit && length $commit ? $commit : 'unknown';
}

sub _redacted_dsn {
    my $dsn = $ENV{GPFORUM_DATABASE_DSN} || q{};
    $dsn =~ s/password=[^;]+/password=REDACTED/gmsx;

    return $dsn;
}

sub _list_text {
    my ($values) = @_;

    return 'none' if !@{$values};

    return join q{,}, @{$values};
}

sub _usage {
    return
'Usage: script/bench-hypnotoad [--json] [--check] [--dry-run] [--seed] [--profile small|medium|hot-thread] [--workers N] [--iterations N] [--warmup N] [--route /path] [--port N] [--no-compare] [--regression-tolerance N]';
}

1;
