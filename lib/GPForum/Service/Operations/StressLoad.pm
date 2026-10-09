# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::StressLoad;

use Const::Fast;
use GPForum::X::Argument;
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::IOLoop;
use Mojo::UserAgent;
use Time::HiRes qw(time);

use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);

our $VERSION = '0.001';

const my $EXIT_FAILURE           => 1;
const my $MILLISECONDS           => 1_000;
const my $PERCENT                => 100;
const my $P50                    => 50;
const my $P95                    => 95;
const my $P99                    => 99;
const my $MIN_ELAPSED            => 0.000_001;
const my $HTTP_OK_MIN            => 200;
const my $HTTP_OK_MAX            => 399;
const my $DEFAULT_TIMEOUT        => 30;
const my $DEFAULT_MAX_ERROR_RATE => 1;
const my $DEFAULT_P95_LIMIT_MS   => 2_000;
const my %PROFILES => (
    smoke => {
        concurrency         => 4,
        requests_per_client => 5,
        description         => 'local smoke; not a capacity claim',
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

sub run ( $self, $options ) {
    my $plan = $self->plan($options);
    return evidence_finalize( _dry_run_evidence($plan) ) if $options->{dry_run};

    if ( !_has_text( $options->{base_url} ) ) {
        GPForum::X::Argument->throw( message =>
              'GPForum stress-load requires --base-url (running Hypnotoad/app)'
        );
    }

    my ( $evidence, $failure );
    try {
        $evidence = $self->_execute( $plan, $options );
    }
    catch ($error) {
        $failure = $error;
    };
    if ( !$evidence ) {
        return evidence_finalize(
            {
                status        => 'fail',
                mode          => 'stress-load',
                error         => _trim_error($failure),
                plan          => $plan,
                prerequisites => _prerequisites($options),
            }
        );
    }

    return evidence_finalize($evidence);
}

sub plan ( $self, $options ) {
    my $profile_name = $options->{profile} // 'smoke';
    if ( !exists $PROFILES{$profile_name} ) {
        GPForum::X::Argument->throw(
            message => "Unsupported stress profile: $profile_name" );
    }
    my $profile = $PROFILES{$profile_name};

    my $concurrency = $options->{concurrency} // $profile->{concurrency};
    my $requests_per_client = $options->{requests_per_client}
      // $profile->{requests_per_client};
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
        request_timeout_s   => $options->{request_timeout} // $DEFAULT_TIMEOUT,
        max_error_rate_pct  => $options->{max_error_rate}
          // $DEFAULT_MAX_ERROR_RATE,
        p95_limit_ms => $options->{p95_limit_ms} // $DEFAULT_P95_LIMIT_MS,
    };
}

sub format_evidence ( $self, $evidence, $format ) {
    return encode_json($evidence) . "\n" if $format eq 'json';

    return _human_evidence($evidence);
}

sub exit_status ( $self, $evidence ) {
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
    my $errors        = 0;
    my $completed     = 0;
    my $inflight      = 0;
    my $next_index    = 0;
    my $total         = $plan->{total_requests};
    my $routes        = $plan->{routes};
    my $route_count   = scalar @{$routes};
    my $started_at    = time;
    my $peak_inflight = 0;

    my $pump;
    $pump = sub {
        while ( $inflight < $plan->{concurrency} && $next_index < $total ) {
            my $request_index = $next_index++;
            my $route         = $routes->[ $request_index % $route_count ];
            my $url           = $base . $route;
            $inflight++;
            if ( $inflight > $peak_inflight ) {
                $peak_inflight = $inflight;
            }
            my $request_started = time;
            $ua->get(
                $url => sub {
                    my ( undef, $tx ) = @_;
                    my $elapsed_ms =
                      ( time - $request_started ) * $MILLISECONDS;
                    $inflight--;
                    $completed++;
                    push @latencies, $elapsed_ms;

                    # Mojo sets $tx->error for HTTP 4xx/5xx as well as
                    # transport failures. Prefer the response code when present
                    # so evidence records 503/etc instead of a bare "error".
                    my $code = $tx->res->code;
                    if ( defined $code && $code > 0 ) {
                        $statuses{$code}++;
                        if ( $code < $HTTP_OK_MIN || $code > $HTTP_OK_MAX ) {
                            $errors++;
                        }
                    }
                    else {
                        $errors++;
                        $statuses{error}++;
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
    if ( $inflight > 0 ) {
        Mojo::IOLoop->start;
    }

    my $elapsed    = time - $started_at;
    my $summary    = _latency_summary( \@latencies, \%statuses, $elapsed );
    my $error_rate = $total > 0 ? ( $errors * $PERCENT ) / $total : 0;
    my $status     = _check_status( $summary, $error_rate, $plan, $options );

    return {
        status         => $status,
        mode           => 'stress-load',
        plan           => $plan,
        prerequisites  => _prerequisites($options),
        wall_seconds   => _rounded($elapsed),
        completed      => $completed,
        errors         => $errors,
        error_rate_pct => _rounded($error_rate),
        peak_inflight  => $peak_inflight,
        req_per_sec    => $summary->{req_per_sec},
        p50_ms         => $summary->{p50_ms},
        p95_ms         => $summary->{p95_ms},
        p99_ms         => $summary->{p99_ms},
        max_ms         => $summary->{max_ms},
        status_codes   => \%statuses,
        residual_gaps  => [
'Harness proves request concurrency against a running instance; it does not alone prove private-beta readiness or staging multicore capacity.'
        ],
    };
}

sub _dry_run_evidence ($plan) {
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

sub _prerequisites ($options) {
    return {
        base_url_required => 1,
        base_url          => $options->{base_url},
        database_dsn      => $ENV{GPFORUM_DATABASE_DSN} ? 'set' : 'unset',
        seeded_db_hint    =>
'Seed with script/seed-performance-data (or --seed on bench-hypnotoad) so forum routes return 200.',
        running_app_hint =>
'Point --base-url at a running Hypnotoad (or reverse-proxy fronting it). This harness does not start the server.',
        ci_default =>
'Not part of make check / default CI. Optional: make stress-load PROFILE=smoke BASE_URL=...',
    };
}

sub _check_status ( $summary, $error_rate, $plan, $options ) {
    return 'ok' if !$options->{check};

    return 'fail' if $error_rate > $plan->{max_error_rate_pct};
    return 'fail' if $summary->{p95_ms} > $plan->{p95_limit_ms};

    return 'pass';
}

sub _latency_summary ( $latencies, $statuses, $elapsed ) {
    my @sorted = sort { $a <=> $b } @{$latencies};
    my $count  = scalar @sorted;
    my $rps    = $count / ( $elapsed > 0 ? $elapsed : $MIN_ELAPSED );

    return {
        req_per_sec  => _rounded($rps),
        p50_ms       => _rounded( _percentile( \@sorted, $P50 ) ),
        p95_ms       => _rounded( _percentile( \@sorted, $P95 ) ),
        p99_ms       => _rounded( _percentile( \@sorted, $P99 ) ),
        max_ms       => _rounded( $sorted[-1] || 0 ),
        status_codes => $statuses,
    };
}

sub _percentile ( $sorted, $percentile ) {
    return 0 if !@{$sorted};

    my $index = int( ( ( @{$sorted} - 1 ) * $percentile ) / $PERCENT );
    return $sorted->[$index];
}

sub _human_evidence ($evidence) {
    my $plan = $evidence->{plan} // {};
    my $text =
        "stress-load status=$evidence->{status}"
      . " profile=$plan->{profile}"
      . " concurrency=$plan->{concurrency}"
      . " requests_per_client=$plan->{requests_per_client}"
      . " total_requests=$plan->{total_requests}\n";

    if ( $evidence->{status} eq 'dry-run' ) {
        $text .=
            'base_url='
          . ( $plan->{base_url} // 'unset' )
          . ' routes='
          . join( q{,}, @{ $plan->{routes} // [] } ) . "\n";
        $text .= "note=dry-run; no HTTP traffic sent\n";
        return $text;
    }

    $text .=
        'wall_seconds='
      . ( $evidence->{wall_seconds} // 'n/a' )
      . ' completed='
      . ( $evidence->{completed} // 0 )
      . ' errors='
      . ( $evidence->{errors} // 0 )
      . ' error_rate_pct='
      . ( $evidence->{error_rate_pct} // 'n/a' )
      . ' peak_inflight='
      . ( $evidence->{peak_inflight} // 0 ) . "\n";
    $text .=
        'req_per_sec='
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

sub _normalize_base_url ($base) {
    $base =~ s{/\z}{}msx;
    return $base;
}

sub _has_text ($value) {
    return defined $value && length $value;
}

sub _trim_error ($error) {
    $error = defined $error && length $error ? $error : 'unknown error';
    $error =~ s/\s+\z//msx;
    return $error;
}

sub _rounded ($value) {
    return sprintf '%.3f', $value;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::StressLoad - Concurrent HTTP load against a running instance, reported as evidence.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $stress   = GPForum::Service::Operations::StressLoad->new;
    my $evidence = $stress->run(
        {
            base_url => 'http://127.0.0.1:8080',
            check    => 1,
            profile  => 'smoke',
        }
    );
    print $stress->format_evidence( $evidence, 'json' );
    exit $stress->exit_status($evidence);

=head1 DESCRIPTION

The engine behind C<bin/gpforum-stress-load>
(L<GPForum::Command::StressLoad>). It sends GET requests to a set of routes
on an instance that is already running, and never starts one. Up to
C<concurrency> requests are in flight at once on one L<Mojo::IOLoop>,
round-robin over the routes, and redirects are not followed. Each request's
latency and status code are recorded; a 2xx or 3xx response is a success,
anything else, a transport failure included, an error.

The profiles are C<smoke> (4 slots of 5 requests each, not a capacity
claim) and C<100>, C<500> and C<1000> (that many slots of 10 requests
each). The default routes are the home page, the category list, one
category, one thread, a search and the two health checks, with the seed
data's ids.

With C<check>, the run fails when the error rate is above
C<max_error_rate> (a percentage, default 1) or the 95th percentile latency
above C<p95_limit_ms> (default 2000); without it the status is C<ok>
whatever the numbers. The evidence goes through
L<GPForum::Service::Operations::EvidenceMeta>'s C<evidence_finalize>, which
adds the default private-beta readiness gap when no listed gap mentions it,
de-duplicates the residual gaps, sets C<private_beta_claimed> to 0 and
marks C<secrets_redacted>.

=head1 SUBROUTINES/METHODS

=head2 profiles

Returns a copy of the profile table: name to
C<< { concurrency, requests_per_client, description } >>.

=head2 run

Takes a hash reference with C<profile> (default C<smoke>),
C<concurrency>, C<requests_per_client>, C<routes> (an array reference of
paths), C<base_url>, C<request_timeout> (seconds, default 30, applied to
connecting, inactivity and the whole request), C<max_error_rate>,
C<p95_limit_ms>, C<check> and C<dry_run>. With C<dry_run>, returns
C<dry-run> evidence holding the plan, and sends nothing. Otherwise returns
evidence with C<status> (C<ok>, C<pass> or C<fail>), C<mode>, C<plan>,
C<prerequisites>, C<wall_seconds>, C<completed>, C<errors>,
C<error_rate_pct>, C<peak_inflight>, C<req_per_sec>, C<p50_ms>, C<p95_ms>,
C<p99_ms>, C<max_ms>, C<status_codes> (counts by code, C<error> for
transport failures) and C<residual_gaps>, plus the keys
C<evidence_finalize> adds. If the run itself dies, returns C<fail> evidence
with the error instead.

=head2 plan

Takes the same options. Returns the run plan: C<profile>,
C<profile_description>, C<concurrency>, C<requests_per_client>,
C<total_requests> (their product), C<routes>, C<base_url>,
C<request_timeout_s>, C<max_error_rate_pct> and C<p95_limit_ms>, each
option given overriding the profile's value or the default.

=head2 format_evidence

Takes evidence and a format. Returns the evidence as one line of JSON for
C<json>, and as a short C<key=value> text summary otherwise.

=head2 exit_status

Takes evidence. Returns 0 for status C<pass>, C<ok> or C<dry-run>, and 1
otherwise.

=head1 DIAGNOSTICS

C<plan>, and so C<run>, croaks C<Unsupported stress profile: NAME>. C<run>
croaks C<GPForum stress-load requires --base-url (running Hypnotoad/app)>
when it is not a dry run and has no base URL. Failures during the load are
returned as C<fail> evidence, not thrown.

=head1 CONFIGURATION AND ENVIRONMENT

C<GPFORUM_DATABASE_DSN> is reported in the prerequisites as set or unset;
it is not otherwise used.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::EvidenceMeta>, L<Mojo::UserAgent>,
L<Mojo::IOLoop>, L<JSON::MaybeXS>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

It proves request concurrency against a running instance. As the residual
gap in its evidence says, it does not by itself prove private-beta readiness
or staging multicore capacity.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
