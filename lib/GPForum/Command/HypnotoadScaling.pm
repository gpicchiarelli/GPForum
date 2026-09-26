# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::HypnotoadScaling;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Command::HypnotoadBenchmark;
use GPForum::Command::PerformanceSeed;

our $VERSION = '0.001';

const my $DEFAULT_ITERATIONS           => 20;
const my $DEFAULT_WARMUP               => 3;
const my $DEFAULT_REGRESSION_TOLERANCE => 5;
const my @DEFAULT_WORKER_COUNTS        => ( 2, 4, 8 );
const my @DEFAULT_ROUTES => (
    q{/categories},
    q{/c/018f1001-0001-7000-8000-000000000001},
    q{/t/018f1004-0001-7000-8000-000000000001},
    q{/search?q=performance},
);

# --help is answered before anything is parsed, and a parse failure becomes a
# usage error rather than an uncaught croak: this used to exit 255 with
# " at FILE line N." glued to the help text.
sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $status = eval { return $self->_run(@arguments); };
    return $status if defined $status;

    return GPForum::Command::Usage->error(
        GPForum::Command::Usage->trimmed($EVAL_ERROR), _usage() );
}

sub _run ( $self, @arguments ) {
    my $options = _options(@arguments);
    my $report  = $self->scaling_report($options);

    print $self->format_report( $report, $options->{format} )
      or croak 'failed to write hypnotoad scaling benchmark report';

    return $options->{check} && $report->{status} ne 'ok' ? 1 : 0;
}

sub scaling_report ( $self, $options ) {
    _seed_profile($options) if $options->{seed} && !$options->{dry_run};

    my @reports;
    my $benchmark = GPForum::Command::HypnotoadBenchmark->new;
    for my $workers ( @{ $options->{worker_counts} } ) {
        push @reports,
          $benchmark->benchmark_report(
            _benchmark_options( $options, $workers ) );
    }

    return {
        mode       => 'hypnotoad-scaling',
        status     => _overall_status( \@reports ),
        iterations => $options->{iterations},
        warmup     => $options->{warmup},
        dataset    => { profile => $options->{profile} },
        routes     => $options->{routes},
        workers    => [ @{ $options->{worker_counts} } ],
        reports    => \@reports,
    };
}

sub format_report ( $self, $report, $format ) {
    return encode_json($report) . "\n" if $format eq 'json';

    return _text_report($report);
}

sub _benchmark_options ( $options, $workers ) {
    return {
        accepts              => $options->{accepts},
        backlog              => $options->{backlog},
        check                => $options->{check},
        clients              => $options->{clients},
        compare_in_process   => $options->{compare_in_process},
        dry_run              => $options->{dry_run},
        format               => $options->{format},
        graceful             => $options->{graceful},
        inactivity           => $options->{inactivity},
        iterations           => $options->{iterations},
        keep_alive           => $options->{keep_alive},
        port                 => undef,
        profile              => $options->{profile},
        regression_tolerance => $options->{regression_tolerance},
        routes               => [ @{ $options->{routes} } ],
        seed                 => 0,
        warmup               => $options->{warmup},
        workers              => $workers,
    };
}

sub _seed_profile ($options) {
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

sub _text_report ($report) {
    my $text =
        "mode=$report->{mode} status=$report->{status}"
      . " iterations=$report->{iterations} warmup=$report->{warmup}"
      . " dataset_profile=$report->{dataset}{profile}"
      . " workers="
      . join( q{,}, @{ $report->{workers} } ) . "\n";

    for my $worker_report ( @{ $report->{reports} } ) {
        $text .= _worker_report_text($worker_report);
    }

    return $text;
}

sub _worker_report_text ($report) {
    my $workers = $report->{runtime}{workers_requested} || 'unknown';
    my $text =
        "worker_set workers=$workers"
      . " status=$report->{status}"
      . " actual_reactor="
      . _actual_reactor($report)
      . " reuseport_configured="
      . _reuseport_configured($report) . "\n";

    for my $route ( @{ $report->{routes} || [] } ) {
        next if ref $route ne 'HASH';
        $text .= join q{ },
          'worker_route',
          'workers=' . $workers,
          'route=' . $route->{route},
          'status=' . $route->{status},
          'req_per_sec=' . $route->{req_per_sec},
          'p50_ms=' . $route->{p50_ms},
          'p95_ms=' . $route->{p95_ms},
          'p99_ms=' . $route->{p99_ms},
          'db_queries=' . _db_query_text( $route->{db_queries} ),
          "\n";
    }

    return $text;
}

sub _actual_reactor ($report) {
    return $report->{runtime}{os_evidence}{event_loop}{actual_reactor_class}
      || 'unknown';
}

sub _reuseport_configured ($report) {
    return $report->{runtime}{os_evidence}{hypnotoad}{reuseport_configured}
      || 0;
}

sub _db_query_text ($summary) {
    return 'not-observed' if !$summary || !$summary->{observed};

    return join q{,},
      'max=' . $summary->{max_queries},
      'avg=' . $summary->{avg_queries},
      'duplicates=' . $summary->{max_duplicate_queries},
      'budget=' . $summary->{budget_status};
}

sub _overall_status ($reports) {
    my $dry_run_count = 0;
    for my $report ( @{$reports} ) {
        if ( $report->{status} eq 'dry-run' ) {
            $dry_run_count++;
            next;
        }
        return 'fail' if $report->{status} ne 'ok';
    }
    return 'dry-run' if $dry_run_count == @{$reports};

    return 'ok';
}

sub _options (@arguments) {
    my $options = {
        accepts              => 100,
        backlog              => 128,
        check                => 0,
        clients              => 100,
        compare_in_process   => 0,
        dry_run              => 0,
        format               => 'text',
        graceful             => 10,
        inactivity           => 30,
        iterations           => $DEFAULT_ITERATIONS,
        keep_alive           => 5,
        profile              => 'small',
        regression_tolerance => $DEFAULT_REGRESSION_TOLERANCE,
        routes               => [],
        seed                 => 0,
        warmup               => $DEFAULT_WARMUP,
        worker_counts        => [@DEFAULT_WORKER_COUNTS],
    };

    while (@arguments) {
        _consume_option( $options, \@arguments );
    }
    if ( !@{ $options->{routes} } ) {
        $options->{routes} = [@DEFAULT_ROUTES];
    }

    return $options;
}

sub _consume_option ( $options, $arguments ) {
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
        '--dry-run'    => sub { $options->{dry_run}            = 1; },
        '--json'       => sub { $options->{format}             = 'json'; },
        '--no-compare' => sub { $options->{compare_in_process} = 0; },
        '--compare'    => sub { $options->{compare_in_process} = 1; },
        '--seed'       => sub { $options->{seed}               = 1; },
        '--profile'    =>
          sub { $options->{profile} = _profile( shift @{$arguments} ); },
        '--iterations' => sub {
            $options->{iterations} = _positive_integer( shift @{$arguments} );
        },
        '--warmup' => sub {
            $options->{warmup} = _non_negative_integer( shift @{$arguments} );
        },
        '--regression-tolerance' => sub {
            $options->{regression_tolerance} =
              _non_negative_number( shift @{$arguments} );
        },
        '--route' => sub {
            push @{ $options->{routes} }, _route( shift @{$arguments} );
        },
        '--worker-set' => sub {
            $options->{worker_counts} = _worker_counts( shift @{$arguments} );
        },
    );

    my $handler = $handler_for{$argument};
    croak _usage() if !$handler;
    $handler->();

    return;
}

sub _worker_counts ($value) {
    croak _usage() if !defined $value || !length $value;

    my @counts = split /,/msx, $value;
    croak _usage() if !@counts;

    return [ map { _positive_integer($_) } @counts ];
}

sub _positive_integer ($value) {
    croak _usage()
      if !defined $value || $value !~ /\A [1-9][[:digit:]]* \z/msx;

    return int $value;
}

sub _non_negative_integer ($value) {
    croak _usage() if !defined $value || $value !~ /\A [[:digit:]]+ \z/msx;

    return int $value;
}

sub _non_negative_number ($value) {
    croak _usage()
      if !defined $value
      || $value !~
      /\A (?: [[:digit:]]+ (?: [.] [[:digit:]]+ )? | [.] [[:digit:]]+ ) \z/msx;

    return 0 + $value;
}

sub _route ($value) {
    croak _usage() if !defined $value || $value !~ m{\A /}msx;

    return $value;
}

sub _profile ($value) {
    croak _usage()
      if !defined $value
      || ( $value ne 'small'
        && $value ne 'medium'
        && $value ne 'hot-thread' );

    return $value;
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
      . ' [--json] [--check] [--dry-run] [--seed] [--profile small|medium|hot-thread] [--worker-set 2,4,8] [--iterations N] [--warmup N] [--route /path] [--compare] [--regression-tolerance N]';
}

1;
