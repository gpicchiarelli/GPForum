# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::HypnotoadScaling;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Usage;
use GPForum::Command::HypnotoadBenchmark;
use GPForum::Command::PerformanceSeed;
use GPForum::X::Usage;

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
const my $ROUTE => qr{\A /}msx;
const my %SWITCH_OPTION => (
    '--check'      => { check              => 1 },
    '--compare'    => { compare_in_process => 1 },
    '--dry-run'    => { dry_run            => 1 },
    '--json'       => { format             => 'json' },
    '--no-compare' => { compare_in_process => 0 },
    '--seed'       => { seed               => 1 },
);

# Each option taking a number: the option it sets and the number's shape.
const my %NUMBER_OPTION => (
    '--accepts'              => [ accepts    => 'positive_integer' ],
    '--backlog'              => [ backlog    => 'positive_integer' ],
    '--clients'              => [ clients    => 'positive_integer' ],
    '--iterations'           => [ iterations => 'positive_integer' ],
    '--regression-tolerance' =>
      [ regression_tolerance => 'non_negative_number' ],
    '--warmup' => [ warmup => 'non_negative_integer' ],
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
    my $report  = $self->scaling_report($options);

    print $self->format_report( $report, $options->{format} )
      or croak 'failed to write hypnotoad scaling benchmark report';

    return $options->{check} && $report->{status} ne 'ok' ? 1 : 0;
}

sub scaling_report ( $self, $options ) {
    if ( $options->{seed} && !$options->{dry_run} ) {
        GPForum::Command::PerformanceSeed->new->seed_profile(
            $options->{profile} );
    }

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

sub _text_report ($report) {
    my $text =
        "mode=$report->{mode} status=$report->{status}"
      . " iterations=$report->{iterations} warmup=$report->{warmup}"
      . " dataset_profile=$report->{dataset}{profile}"
      . q{ workers=}
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
      . q{ actual_reactor=}
      . _actual_reactor($report)
      . q{ reuseport_configured=}
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
    my $usage   = _usage();
    my $options = GPForum::Command::Usage->parse_options(
        \@arguments,
        {
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
                '--route' => sub ( $options, $value ) {
                    push @{ $options->{routes} },
                      GPForum::Command::Usage->option_value( $value, $ROUTE,
                        $usage );
                },
                '--worker-set' => sub ( $options, $value ) {
                    my @counts = split /,/msx, $value // q{};
                    if ( !@counts ) {
                        GPForum::X::Usage->throw( message => $usage );
                    }
                    $options->{worker_counts} = [
                        map {
                            GPForum::Command::Usage->option_number( $_,
                                'positive_integer', $usage )
                        } @counts
                    ];
                },
            },
        },
    );
    if ( !@{ $options->{routes} } ) {
        $options->{routes} = [@DEFAULT_ROUTES];
    }

    return $options;
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
