package GPForum::Service::Operations::StressLoad;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base;
use Mojo::IOLoop;
use Mojo::UserAgent;
use Time::HiRes qw(time);

our $VERSION = '0.001';

const my $EXIT_FAILURE     => 1;
const my $MILLISECONDS     => 1_000;
const my $PERCENT          => 100;
const my $P50              => 50;
const my $P95              => 95;
const my $P99              => 99;
const my $MIN_ELAPSED      => 0.000_001;
const my $HTTP_OK_MIN      => 200;
const my $HTTP_OK_MAX      => 399;
const my $DEFAULT_TIMEOUT  => 30;
const my $DEFAULT_MAX_ERROR_RATE => 1;
const my $DEFAULT_P95_LIMIT_MS   => 2_000;
const my %PROFILES => (
    smoke => {
        concurrency          => 4,
        requests_per_client  => 5,
        description          => 'local smoke; not a capacity claim',
    },
    100 => {
        concurrency         => 100,
        requests_per_client => 10,
        description         => '100 concurrent request slots',
    },
    500 => {
        concurrency         => 500,
        requests_per_client => 10,
        description         => '500 concurrent request slots',
    },
    1000 => {
        concurrency         => 1_000,
        requests_per_client => 10,
        description         => '1000 concurrent request slots',
    },
);
const my @DEFAULT_ROUTES => (
    q{/},
    q{/categories},
    q{/c/018f1001-0001-7000-8000-000000000001},
    q{/t/018f1004-0001-7000-8000-000000000001},
    q{/search?q=performance},
    q{/health/live},
    q{/health/ready},
);

sub profiles {
    return {%PROFILES};
}

sub run {
    my ( $self, $options ) = @_;

    my $plan = $self->plan($options);
    return _dry_run_evidence($plan) if $options->{dry_run};

    croak 'GPForum stress-load requires --base-url (running Hypnotoad/app)'
      if !_has_text( $options->{base_url} );

    my $evidence = eval { return $self->_execute( $plan, $options ) };
    if ( !$evidence ) {
        return {
            status      => 'fail',
            mode        => 'stress-load',
            error       => _trim_error($EVAL_ERROR),
            plan        => $plan,
            prerequisites => _prerequisites($options),
        };
    }

    return $evidence;
}

sub plan {
    my ( $self, $options ) = @_;

    my $profile_name = $options->{profile} // 'smoke';
    my $profile      = $PROFILES{$profile_name}
      or croak "Unsupported stress profile: $profile_name";

    my $concurrency = $options->{concurrency} // $profile->{concurrency};
    my $requests_per_client =
      $options->{requests_per_client} // $profile->{requests_per_client};
    my $routes =
      @{ $options->{routes} // [] }
      ? [ @{ $options->{routes} } ]
      : [@DEFAULT_ROUTES];

    return {
        profile             => $profile_name,
        profile_description => $profile->{description},
        concurrency         => $concurrency,
        requests_per_client => $requests_per_client,
        total_requests      => $concurrency * $requests_per_client,
        routes              => $routes,
        base_url            => $options->{base_url},
        request_timeout_s   => $options->{request_timeout}
          // $DEFAULT_TIMEOUT,
        max_error_rate_pct  => $options->{max_error_rate}
          // $DEFAULT_MAX_ERROR_RATE,
        p95_limit_ms        => $options->{p95_limit_ms}
          // $DEFAULT_P95_LIMIT_MS,
    };
}

sub format_evidence {
    my ( $self, $evidence, $format ) = @_;

    return encode_json($evidence) . "\n" if $format eq 'json';

    return _human_evidence($evidence);
}

sub exit_status {
    my ( $self, $evidence ) = @_;

    my $status = $evidence->{status} // q{};
    return 0
      if $status eq 'pass'
      || $status eq 'ok'
      || $status eq 'dry-run';

    return $EXIT_FAILURE;
}

sub _execute {
    my ( $self, $plan, $options ) = @_;

    my $base = _normalize_base_url( $plan->{base_url} );
    my $ua   = Mojo::UserAgent->new;
    $ua->max_redirects(0);
    $ua->request_timeout( $plan->{request_timeout_s} );
    $ua->connect_timeout( $plan->{request_timeout_s} );
    $ua->inactivity_timeout( $plan->{request_timeout_s} );
    $ua->max_connections( $plan->{concurrency} );

    my @latencies;
    my %statuses;
    my $errors       = 0;
    my $completed    = 0;
    my $inflight     = 0;
    my $next_index   = 0;
    my $total        = $plan->{total_requests};
    my $routes       = $plan->{routes};
    my $route_count  = scalar @{$routes};
    my $started_at   = time;
    my $peak_inflight = 0;

    my $pump;
    $pump = sub {
        while ( $inflight < $plan->{concurrency} && $next_index < $total ) {
            my $request_index = $next_index++;
            my $route         = $routes->[ $request_index % $route_count ];
            my $url           = $base . $route;
            $inflight++;
            $peak_inflight = $inflight if $inflight > $peak_inflight;
            my $request_started = time;
            $ua->get(
                $url => sub {
                    my ( undef, $tx ) = @_;
                    my $elapsed_ms =
                      ( time - $request_started ) * $MILLISECONDS;
                    $inflight--;
                    $completed++;
                    push @latencies, $elapsed_ms;
                    my $code = 0;
                    my $err  = $tx->error;
                    if ($err) {
                        $errors++;
                        $statuses{error}++;
                    }
                    else {
                        $code = $tx->res->code || 0;
                        $statuses{$code}++;
                        if ( $code < $HTTP_OK_MIN || $code > $HTTP_OK_MAX ) {
                            $errors++;
                        }
                    }
                    if ( $completed >= $total ) {
                        Mojo::IOLoop->stop;
                        return;
                    }
                    $pump->();
                    return;
                }
            );
        }
        return;
    };

    $pump->();
    Mojo::IOLoop->start if $inflight > 0;

    my $elapsed = time - $started_at;
    my $summary = _latency_summary( \@latencies, \%statuses, $elapsed );
    my $error_rate =
      $total > 0 ? ( $errors * $PERCENT ) / $total : 0;
    my $status = _check_status( $summary, $error_rate, $plan, $options );

    return {
        status          => $status,
        mode            => 'stress-load',
        plan            => $plan,
        prerequisites   => _prerequisites($options),
        wall_seconds    => _rounded($elapsed),
        completed       => $completed,
        errors          => $errors,
        error_rate_pct  => _rounded($error_rate),
        peak_inflight   => $peak_inflight,
        req_per_sec     => $summary->{req_per_sec},
        p50_ms          => $summary->{p50_ms},
        p95_ms          => $summary->{p95_ms},
        p99_ms          => $summary->{p99_ms},
        max_ms          => $summary->{max_ms},
        status_codes    => \%statuses,
        residual_gaps   => [
'Harness proves request concurrency against a running instance; it does not alone prove private-beta readiness or staging multicore capacity.'
        ],
    };
}

sub _dry_run_evidence {
    my ($plan) = @_;

    return {
        status        => 'dry-run',
        mode          => 'stress-load',
        plan          => $plan,
        prerequisites => _prerequisites( { base_url => $plan->{base_url} } ),
        residual_gaps => [
'Dry-run only; no HTTP traffic was sent. Run without --dry-run against a live Hypnotoad/GPForum base URL.'
        ],
    };
}

sub _prerequisites {
    my ($options) = @_;

    return {
        base_url_required => 1,
        base_url          => $options->{base_url},
        database_dsn      => $ENV{GPFORUM_DATABASE_DSN} ? 'set' : 'unset',
        seeded_db_hint =>
'Seed with script/seed-performance-data (or --seed on bench-hypnotoad) so forum routes return 200.',
        running_app_hint =>
'Point --base-url at a running Hypnotoad (or reverse-proxy fronting it). This harness does not start the server.',
        ci_default =>
'Not part of make check / default CI. Optional: make stress-load PROFILE=smoke BASE_URL=...',
    };
}

sub _check_status {
    my ( $summary, $error_rate, $plan, $options ) = @_;

    return 'pass' if !$options->{check};

    return 'fail' if $error_rate > $plan->{max_error_rate_pct};
    return 'fail' if $summary->{p95_ms} > $plan->{p95_limit_ms};

    return 'pass';
}

sub _latency_summary {
    my ( $latencies, $statuses, $elapsed ) = @_;

    my @sorted = sort { $a <=> $b } @{$latencies};
    my $count  = scalar @sorted;
    my $rps    = $count / ( $elapsed > 0 ? $elapsed : $MIN_ELAPSED );

    return {
        req_per_sec => _rounded($rps),
        p50_ms      => _rounded( _percentile( \@sorted, $P50 ) ),
        p95_ms      => _rounded( _percentile( \@sorted, $P95 ) ),
        p99_ms      => _rounded( _percentile( \@sorted, $P99 ) ),
        max_ms      => _rounded( $sorted[-1] || 0 ),
        status_codes => $statuses,
    };
}

sub _percentile {
    my ( $sorted, $percentile ) = @_;

    return 0 if !@{$sorted};

    my $index = int( ( ( @{$sorted} - 1 ) * $percentile ) / $PERCENT );
    return $sorted->[$index];
}

sub _human_evidence {
    my ($evidence) = @_;

    my $plan = $evidence->{plan} // {};
    my $text =
        "stress-load status=$evidence->{status}"
      . " profile=$plan->{profile}"
      . " concurrency=$plan->{concurrency}"
      . " requests_per_client=$plan->{requests_per_client}"
      . " total_requests=$plan->{total_requests}\n";

    if ( $evidence->{status} eq 'dry-run' ) {
        $text .= 'base_url='
          . ( $plan->{base_url} // 'unset' )
          . ' routes='
          . join( q{,}, @{ $plan->{routes} // [] } ) . "\n";
        $text .= "note=dry-run; no HTTP traffic sent\n";
        return $text;
    }

    $text .= 'wall_seconds='
      . ( $evidence->{wall_seconds} // 'n/a' )
      . ' completed='
      . ( $evidence->{completed} // 0 )
      . ' errors='
      . ( $evidence->{errors} // 0 )
      . ' error_rate_pct='
      . ( $evidence->{error_rate_pct} // 'n/a' )
      . ' peak_inflight='
      . ( $evidence->{peak_inflight} // 0 ) . "\n";
    $text .= 'req_per_sec='
      . ( $evidence->{req_per_sec} // 'n/a' )
      . ' p50_ms='
      . ( $evidence->{p50_ms} // 'n/a' )
      . ' p95_ms='
      . ( $evidence->{p95_ms} // 'n/a' )
      . ' p99_ms='
      . ( $evidence->{p99_ms} // 'n/a' )
      . ' max_ms='
      . ( $evidence->{max_ms} // 'n/a' ) . "\n";

    if ( $evidence->{error} ) {
        $text .= "error=$evidence->{error}\n";
    }

    return $text;
}

sub _normalize_base_url {
    my ($base) = @_;

    $base =~ s{/\z}{}msx;
    return $base;
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value;
}

sub _trim_error {
    my ($error) = @_;

    $error = defined $error && length $error ? $error : 'unknown error';
    $error =~ s/\s+\z//msx;
    return $error;
}

sub _rounded {
    my ($value) = @_;

    return sprintf '%.3f', $value;
}

1;
