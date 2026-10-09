# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::HypnotoadBenchmark;

use Carp qw(croak);
use Const::Fast;
use Cwd           qw(abs_path);
use English       qw(-no_match_vars);
use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::UserAgent;
use Mojolicious ();

use GPForum::Benchmark::HypnotoadText qw(text_report);
use GPForum::Benchmark::Measure       qw(
  endpoint_name error_rate header_budget_status overall_status query_summary
  regressions route_summary sample_route server_sample
);
use GPForum::Benchmark::Process qw(
  free_port git_commit read_pid_file spawn terminate wait_for_exit
  wait_until_ready worker_pids
);
use GPForum::Benchmark::ReverseProxy qw(resolve_proxy start_proxy);
use GPForum::Benchmark::SeedDataset  qw(seed_id);
use GPForum::Command::Usage;
use GPForum::Command::Benchmark;
use GPForum::Command::PerformanceSeed;
use GPForum::Config;
use GPForum::OS::RuntimeEvidence;
use GPForum::Schema;
use GPForum::X::Config;
use GPForum::X::Unavailable;

our $VERSION = '0.001';

const my $DEFAULT_ITERATIONS           => 20;
const my $DEFAULT_WARMUP               => 3;
const my $DEFAULT_WORKERS              => 2;
const my $DEFAULT_REGRESSION_TOLERANCE => 5;
const my @SEEDED_ROUTES => (
    q{/},                              q{/categories},
    q{/c/} . seed_id( category => 1 ), q{/t/} . seed_id( thread => 1 ),
    q{/search?q=performance},          q{/search/autocomplete?q=per},
    q{/health/live},                   q{/health/ready},
    q{/metrics},
);
const my $ROUTE => qr{\A /}msx;
const my %SWITCH_OPTION => (
    '--check'             => { check              => 1 },
    '--dry-run'           => { dry_run            => 1 },
    '--json'              => { format             => 'json' },
    '--no-compare'        => { compare_in_process => 0, compare_direct => 0 },
    '--no-direct-compare' => { compare_direct     => 0 },
    '--reverse-proxy'     => { reverse_proxy      => 1 },
    '--seed'              => { seed               => 1 },
);

# Each option taking a number: the option it sets and the number's shape.
const my %NUMBER_OPTION => (
    '--accepts'              => [ accepts       => 'positive_integer' ],
    '--backlog'              => [ backlog       => 'positive_integer' ],
    '--clients'              => [ clients       => 'positive_integer' ],
    '--frontend-port'        => [ frontend_port => 'positive_integer' ],
    '--graceful-timeout'     => [ graceful      => 'positive_integer' ],
    '--iterations'           => [ iterations    => 'positive_integer' ],
    '--keep-alive'           => [ keep_alive    => 'positive_integer' ],
    '--port'                 => [ port          => 'positive_integer' ],
    '--regression-tolerance' =>
      [ regression_tolerance => 'non_negative_number' ],
    '--warmup'  => [ warmup  => 'non_negative_integer' ],
    '--workers' => [ workers => 'positive_integer' ],
);

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
    my $report  = $self->benchmark_report($options);

    print $self->format_report( $report, $options->{format} )
      or croak 'failed to write hypnotoad benchmark report';

    return $options->{check} && $report->{status} ne 'ok' ? 1 : 0;
}

sub benchmark_report ( $self, $options ) {
    return _dry_run_report($options) if $options->{dry_run};

    _assert_database_available();
    if ( $options->{seed} ) {
        GPForum::Command::PerformanceSeed->new->seed_profile(
            $options->{profile} );
    }

    my $resolved_proxy =
      $options->{reverse_proxy}
      ? _resolve_proxy( $options->{proxy_kind} )
      : undef;
    my $in_process =
      $options->{compare_in_process}
      ? _in_process_report($options)
      : undef;

    my $runtime = _start_hypnotoad($options);
    my ( $report, $error, $proxy_runtime );
    try {
        _wait_until_ready( $runtime, 'hypnotoad' );
        if ( $options->{reverse_proxy} ) {
            my $direct =
              $options->{compare_direct}
              ? _runtime_report( $runtime, $options, $in_process )
              : undef;
            $proxy_runtime =
              _start_reverse_proxy( $runtime, $options, $resolved_proxy );
            _wait_until_ready( $proxy_runtime, 'reverse proxy' );
            $report =
              _reverse_proxy_report( $runtime, $proxy_runtime, $options,
                $direct );
        }
        else {
            $report = _runtime_report( $runtime, $options, $in_process );
        }
    }
    catch ($caught) {
        $error = $caught;
    };

    _stop_reverse_proxy($proxy_runtime);
    _stop_hypnotoad($runtime);
    croak $error if defined $error;

    return $report;
}

sub format_report ( $self, $report, $format ) {
    return encode_json($report) . "\n" if $format eq 'json';

    return text_report($report);
}

# The routes measured on one runtime, each compared with its baseline -- the
# in-process report for hypnotoad itself, the direct one behind a proxy --
# and the runtime's metadata, read once they ran.
sub _measured_report ( $runtime, $options, $shape ) {
    my ( $name, $baseline ) = @{ $shape->{baseline} };
    my %baseline_route;
    for my $route ( @{ $baseline ? $baseline->{routes} || [] : [] } ) {
        $baseline_route{ $route->{route} } //= $route;
    }
    my @route_reports =
      map { _route_report( $runtime, $_, $options, $baseline_route{$_} ) }
      @{ $options->{routes} };

    return {
        mode       => $shape->{mode},
        status     => overall_status( \@route_reports ),
        iterations => $options->{iterations},
        warmup     => $options->{warmup},
        routes     => \@route_reports,
        dataset    => { profile => $options->{profile} },
        runtime    => $shape->{metadata}->(),
        comparison => {
            "${name}_enabled"    => $baseline ? 1 : 0,
            regression_tolerance => $options->{regression_tolerance},
            $name                => $baseline,
        },
    };
}

sub _runtime_report ( $runtime, $options, $in_process ) {
    return _measured_report(
        $runtime, $options,
        {
            mode     => 'hypnotoad',
            baseline => [ in_process => $in_process ],
            metadata => sub { return _runtime_metadata( $runtime, $options ) },
        }
    );
}

sub _reverse_proxy_report ( $backend_runtime, $proxy_runtime, $options,
    $direct_report )
{
    return _measured_report(
        $proxy_runtime,
        $options,
        {
            mode     => 'hypnotoad-reverse-proxy',
            baseline => [ direct => $direct_report ],
            metadata => sub {
                return _reverse_proxy_runtime_metadata( $backend_runtime,
                    $proxy_runtime, $options );
            },
        }
    );
}

sub _route_report ( $runtime, $route, $options, $baseline ) {
    my $url = $runtime->{base_url} . $route;
    for ( 1 .. $options->{warmup} ) {
        server_sample( $runtime->{ua}, $url );
    }

    my $samples = sample_route( $options->{iterations},
        sub { return server_sample( $runtime->{ua}, $url ); } );
    my $db_queries = query_summary( $samples->{observations} );
    $db_queries->{budget_status} //=
      header_budget_status( $samples->{observations} );
    my $summary = {
        %{ route_summary( $route, $samples, $db_queries ) },
        query_budget => endpoint_name($route),
        error_rate   => error_rate( $samples->{statuses} ),
    };

    if ($baseline) {
        my @violations =
          regressions( $summary, $baseline, $options->{regression_tolerance} );
        $summary->{comparison} = {
            status   => @violations ? 'fail' : 'ok',
            baseline => {
                map { $_ => $baseline->{$_} }
                  qw(p50_ms p95_ms p99_ms req_per_sec)
            },
            violations => \@violations,
        };
        if (@violations) {
            $summary->{status} = 'fail';
        }
    }

    return $summary;
}

sub _in_process_report ($options) {
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

sub _start_hypnotoad ($options) {
    my $directory   = tempdir( 'gpforum-hypnotoad-XXXXXX', TMPDIR => 1 );
    my $port        = $options->{port} || free_port();
    my $pid_file    = "$directory/hypnotoad.pid";
    my $log_file    = "$directory/hypnotoad.log";
    my $app_file    = "$directory/gpforum-hypnotoad-app.pl";
    my $base_url    = "http://127.0.0.1:$port";
    my %environment = _runtime_environment( $options, $port, $pid_file );

    _write_hypnotoad_app($app_file);

    my $pid = _spawn(
        {
            name        => 'hypnotoad',
            log_file    => $log_file,
            environment => \%environment,
            session     => 1,
        },
        qw(carton exec -- hypnotoad -f),
        $app_file,
    );

    if ( !defined $pid ) {
        GPForum::X::Unavailable->throw(
            message => 'failed to fork hypnotoad benchmark process' );
    }

    return {
        process_pid => $pid,
        directory   => $directory,
        pid_file    => $pid_file,
        log_file    => $log_file,
        app_file    => $app_file,
        base_url    => $base_url,
        port        => $port,
        environment => \%environment,
        ua          => Mojo::UserAgent->new( request_timeout => 5 ),
    };
}

sub _write_hypnotoad_app ($app_file) {
    my $library = abs_path('lib')
      or croak 'failed to resolve GPForum lib directory';
    open my $handle, '>', $app_file
      or croak "failed to write benchmark hypnotoad app $app_file";
    print {$handle} <<"APP" or croak "failed to write $app_file";
use v5.40;
use lib '$library';
use GPForum;
GPForum->new;
APP
    close $handle or croak "failed to close $app_file";

    return;
}

sub _runtime_environment ( $options, $port, $pid_file ) {
    return (
        GPFORUM_LOG_LEVEL                  => 'fatal',
        GPFORUM_BENCHMARK_QUERY_HEADERS    => 1,
        GPFORUM_RUNTIME_LISTEN             => "http://127.0.0.1:$port",
        GPFORUM_RUNTIME_PID_FILE           => $pid_file,
        GPFORUM_RUNTIME_WORKER_POLICY      => 'configured',
        GPFORUM_RUNTIME_PROXY              => $options->{reverse_proxy} ? 1 : 0,
        GPFORUM_RUNTIME_BACKLOG            => $options->{backlog},
        GPFORUM_RUNTIME_CLIENTS            => $options->{clients},
        GPFORUM_RUNTIME_REQUESTS           => $options->{accepts},
        GPFORUM_RUNTIME_KEEP_ALIVE_TIMEOUT => $options->{keep_alive},
        GPFORUM_RUNTIME_INACTIVITY_TIMEOUT => $options->{inactivity},
        GPFORUM_RUNTIME_GRACEFUL_TIMEOUT   => $options->{graceful},
        GPFORUM_WEB_PROCESSES              => $options->{workers},
    );
}

# The process steps, under the names the tests drive and replace them by.
sub _spawn ( $child, @command ) {
    return spawn( $child, @command );
}

sub _terminate ($runtime) {
    return terminate($runtime);
}

sub _wait_until_ready ( $runtime, $name ) {
    return wait_until_ready( $runtime, $name );
}

sub _resolve_proxy ($requested) {
    return resolve_proxy($requested);
}

sub _start_reverse_proxy ( $backend_runtime, $options, $resolved_proxy ) {
    return start_proxy( $backend_runtime, $options,
        $resolved_proxy || _resolve_proxy( $options->{proxy_kind} ) );
}

sub _stop_reverse_proxy ($runtime) {
    return if !$runtime;

    return _terminate($runtime);
}

sub _stop_hypnotoad ($runtime) {
    return if !$runtime;

    my $stopper = _spawn(
        {
            name        => 'hypnotoad stop',
            log_file    => $runtime->{log_file},
            environment => $runtime->{environment},
        },
        qw(carton exec -- hypnotoad -s),
        $runtime->{app_file},
    );
    if ( defined $stopper ) {
        waitpid $stopper, 0;
    }
    wait_for_exit( $runtime->{process_pid} ) and return;

    return _terminate($runtime);
}

sub _runtime_metadata ( $runtime, $options ) {
    my $master_pid = read_pid_file( $runtime->{pid_file} );
    my %environment =
      %{ $runtime->{environment} || {} };
    local %ENV = ( %ENV, %environment );

    return {
        base_url            => $runtime->{base_url},
        port                => $runtime->{port},
        workers_requested   => $options->{workers},
        master_pid          => $master_pid,
        foreground_pid      => $runtime->{process_pid},
        worker_pids         => worker_pids($master_pid),
        app_file            => $runtime->{app_file},
        pid_file            => $runtime->{pid_file},
        log_file            => $runtime->{log_file},
        perl_version        => "$PERL_VERSION",
        mojolicious_version => Mojolicious->VERSION,
        git_commit          => git_commit(),
        database            => { dsn => _redacted_dsn() },
        os_evidence => GPForum::OS::RuntimeEvidence->from_environment->report,
        config      => {
            accepts    => $options->{accepts},
            keep_alive => $options->{keep_alive},
            backlog    => $options->{backlog},
            proxy      => $options->{reverse_proxy} ? 1 : 0,
        },
    };
}

sub _reverse_proxy_runtime_metadata ( $backend_runtime, $proxy_runtime,
    $options )
{
    my $metadata = _runtime_metadata( $backend_runtime, $options );
    $metadata->{backend_hypnotoad} = {
        base_url          => $backend_runtime->{base_url},
        port              => $backend_runtime->{port},
        workers_requested => $options->{workers},
    };
    $metadata->{frontend} = {
        base_url => $proxy_runtime->{base_url},
        port     => $proxy_runtime->{port},
    };
    $metadata->{reverse_proxy} = {
        name        => $proxy_runtime->{kind},
        binary      => $proxy_runtime->{binary},
        version     => $proxy_runtime->{version},
        pid         => $proxy_runtime->{process_pid},
        config_file => $proxy_runtime->{config_file},
        pid_file    => $proxy_runtime->{pid_file},
        log_file    => $proxy_runtime->{log_file},
    };

    return $metadata;
}

sub _assert_database_available {
    my $config = GPForum::Config->from_environment;
    if ( !defined $config->database_dsn || !length $config->database_dsn ) {
        GPForum::X::Config->throw(
            message => 'script/bench-hypnotoad requires GPFORUM_DATABASE_DSN' );
    }

    my $schema = GPForum::Schema->connect_from_config($config);
    $schema->storage->dbh->selectrow_array('SELECT 1');

    return;
}

sub _dry_run_report ($options) {
    my $mode =
      $options->{reverse_proxy} ? 'hypnotoad-reverse-proxy' : 'hypnotoad';
    my $runtime = {
        workers_requested => $options->{workers},
        port              => $options->{port} || 'auto',
        database          => { dsn => _redacted_dsn() },
    };
    if ( $options->{reverse_proxy} ) {
        $runtime->{backend_hypnotoad} = {
            port              => $options->{port} || 'auto',
            workers_requested => $options->{workers},
        };
        $runtime->{frontend} = { port => $options->{frontend_port} || 'auto', };
        $runtime->{reverse_proxy} = {
            requested => $options->{proxy_kind},
            status    => 'dry-run',
        };
    }

    return {
        mode       => $mode,
        status     => 'dry-run',
        iterations => $options->{iterations},
        warmup     => $options->{warmup},
        dataset    => { profile => $options->{profile} },
        routes     => $options->{routes},
        runtime    => $runtime,
        comparison => {
            in_process_enabled => $options->{compare_in_process} ? 1 : 0,
            direct_enabled     => $options->{reverse_proxy}
              && $options->{compare_direct} ? 1 : 0,
            regression_tolerance => $options->{regression_tolerance},
        },
    };
}

sub _options (@arguments) {
    my $usage   = _usage();
    my $options = GPForum::Command::Usage->parse_options(
        \@arguments,
        {
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
            frontend_port        => undef,
            proxy_kind           => 'auto',
            reverse_proxy        => 0,
            compare_direct       => 1,
        },
        {
            usage    => $usage,
            switches => \%SWITCH_OPTION,
            numbers  => \%NUMBER_OPTION,
            values   => {
                '--profile' => sub ( $options, $value ) {
                    $options->{profile} =
                      GPForum::Command::Usage->option_choice( $value,
                        [ GPForum::Command::PerformanceSeed->profiles ],
                        $usage );
                },
                '--proxy' => sub ( $options, $value ) {
                    $options->{proxy_kind} =
                      GPForum::Command::Usage->option_choice( $value,
                        [qw(auto nginx haproxy)], $usage );
                    $options->{reverse_proxy} = 1;
                },
                '--route' => sub ( $options, $value ) {
                    push @{ $options->{routes} },
                      GPForum::Command::Usage->option_value( $value, $ROUTE,
                        $usage );
                },
            },
        },
    );
    if ( !@{ $options->{routes} } ) {
        $options->{routes} = [@SEEDED_ROUTES];
    }

    return $options;
}

sub _redacted_dsn {
    my $dsn = $ENV{GPFORUM_DATABASE_DSN} || q{};
    $dsn =~ s/password=[^;]+/password=REDACTED/gmsx;

    return $dsn;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return
        'Usage: '
      . GPForum::Command::Usage->program
      . ' [--json] [--check] [--dry-run] [--seed] [--profile small|medium|hot-thread] [--workers N] [--iterations N] [--warmup N] [--route /path] [--port N] [--reverse-proxy] [--proxy auto|nginx|haproxy] [--frontend-port N] [--no-compare] [--no-direct-compare] [--regression-tolerance N]';
}

1;
