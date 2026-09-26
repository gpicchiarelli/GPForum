# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::RateLimiter;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Clock;
use GPForum::Service::Operations::RateLimiter::DegradationPolicy;
use GPForum::Service::Operations::RateLimiter::LocalMemoryStore;

our $VERSION = '0.001';

const my $SCHEMA_VERSION           => 1;
const my $DEFAULT_LIMIT            => 60;
const my $DEFAULT_WINDOW_SECONDS   => 60;
const my $HTTP_TOO_MANY_REQUESTS   => 429;
const my $DENIED_OVER_LIMIT        => 'over_limit';
const my $DENIED_STORE_UNAVAILABLE => 'store_unavailable';
const my $UNAVAILABLE_STORE        => 'unavailable';

has clock              => sub { return GPForum::Service::Clock->new; };
has degradation_policy => sub {
    return GPForum::Service::Operations::RateLimiter::DegradationPolicy->new;
};
has fallback_store => sub {
    my ($self) = @_;

    return GPForum::Service::Operations::RateLimiter::LocalMemoryStore->new(
        clock => $self->clock, );
};
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has primary_store => undef;
has recorder      => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema             => undef;
has security_telemetry => undef;
has stats              => sub {
    return {
        allowed            => 0,
        audit_failures     => 0,
        blocked            => 0,
        blocked_degraded   => 0,
        blocked_over_limit => 0,
        checks             => 0,
        fallback_used      => 0,
        primary_failures   => 0,
    };
};

sub check ( $self, $input ) {
    my $decision = $self->_check_primary($input);
    if ( !$decision ) {
        $decision = $self->_degraded_decision($input);
    }

    _mark_denied_reason($decision);
    $self->_record_decision( $input, $decision );

    return $decision;
}

sub snapshot ($self) {
    my $store_snapshot = $self->_store_snapshot;

    return {
        %{$store_snapshot},
        degradation_mode => $self->degradation_policy->mode,
        fail_closed      => $self->degradation_policy->fail_closed,
        stats            => { %{ $self->stats } },
    };
}

sub _check_primary ( $self, $input ) {
    my $undefined;
    return $undefined if !$self->primary_store;

    my $decision = eval { return $self->primary_store->check($input); };
    if ( !$decision ) {
        $self->stats->{primary_failures} += 1;
        $self->_telemetry(
            'rate_limit_store_degraded',
            {
                action   => $input->{action},
                degraded => 1,
                reason   => 'primary_store_failed',
                store    => 'postgresql',
            },
        );
        return $undefined;
    }

    return $decision;
}

sub _degraded_decision ( $self, $input ) {
    return $self->_check_fallback($input) if !$self->primary_store;
    return $self->_check_fallback($input)
      if !$self->degradation_policy->fail_closed;

    return $self->_fail_closed_decision($input);
}

sub _check_fallback ( $self, $input ) {
    my $decision = $self->fallback_store->check($input);
    if ( $self->primary_store ) {
        $decision->{degraded} = 1;
        $self->stats->{fallback_used} += 1;
    }

    return $decision;
}

sub _fail_closed_decision ( $self, $input ) {
    my $limit          = $input->{limit}          || $DEFAULT_LIMIT;
    my $window_seconds = $input->{window_seconds} || $DEFAULT_WINDOW_SECONDS;

    $self->_telemetry(
        'rate_limit_fail_closed',
        {
            action   => $input->{action},
            degraded => 1,
            reason   => $DENIED_STORE_UNAVAILABLE,
            status   => $HTTP_TOO_MANY_REQUESTS,
            store    => $UNAVAILABLE_STORE,
        },
    );

    return {
        ok              => 0,
        key             => _fail_closed_key($input),
        limit           => $limit,
        remaining       => 0,
        reset_at_epoch  => $self->clock->now_epoch + $window_seconds,
        store           => $UNAVAILABLE_STORE,
        window_seconds  => $window_seconds,
        observed_count  => $limit,
        mitigation_hint => 'retry_after_backoff',
        degraded        => 1,
        denied_reason   => $DENIED_STORE_UNAVAILABLE,
    };
}

sub _record_decision ( $self, $input, $decision ) {
    $self->stats->{checks} += 1;
    if ( $decision->{ok} ) {
        $self->stats->{allowed} += 1;
        return;
    }

    $self->_record_block_stats($decision);
    $self->_telemetry(
        'rate_limit_hit',
        {
            action   => $input->{action},
            degraded => $decision->{degraded} ? 1 : 0,
            reason   => $decision->{denied_reason},
            status   => $HTTP_TOO_MANY_REQUESTS,
            store    => $decision->{store},
        },
    );
    $self->_record_block_audit( $input, $decision );

    return;
}

sub _record_block_stats ( $self, $decision ) {
    $self->stats->{blocked} += 1;
    my $counter =
      _store_unavailable($decision)
      ? 'blocked_degraded'
      : 'blocked_over_limit';
    $self->stats->{$counter} += 1;

    return;
}

sub _record_block_audit ( $self, $input, $decision ) {
    my $undefined;
    return $undefined if !$self->schema;
    return $undefined if _store_unavailable($decision);

    my $created = eval {
        return $self->recorder->record_audit(
            action     => 'rate_limit.blocked',
            actor_id   => _uuid_or_undef( $input->{actor_id} ),
            created_at => $self->clock->now_iso8601,
            metadata   => {
                action         => $input->{action},
                actor_hash     => _actor_hash($input),
                limit          => $decision->{limit},
                observed_count => $decision->{observed_count},
                scope          => $input->{scope},
                store          => $decision->{store},
                window_seconds => $decision->{window_seconds},
            },
            previous_hash  => undef,
            record_hash    => q{},
            schema_version => $SCHEMA_VERSION,
            target_id      => undef,
            target_type    => 'rate_limit',
        );
    };

    if ( !$created ) {
        $self->stats->{audit_failures} += 1;
    }

    return $undefined;
}

sub _store_snapshot ($self) {
    my $snapshot = eval {
        return $self->primary_store
          ? $self->primary_store->snapshot
          : $self->fallback_store->snapshot;
    };

    if ($snapshot) {
        $snapshot->{fallback} = $self->fallback_store->snapshot
          if $self->primary_store;
        return $snapshot;
    }

    my $fallback = $self->fallback_store->snapshot;
    $fallback->{status}   = 'degraded';
    $fallback->{fallback} = 1;

    return $fallback;
}

sub _telemetry ( $self, $event_type, $metadata ) {
    my $undefined;
    return $undefined if !$self->security_telemetry;

    return $self->security_telemetry->record( $event_type, $metadata );
}

sub _mark_denied_reason ($decision) {
    return if $decision->{ok};

    $decision->{denied_reason} ||= $DENIED_OVER_LIMIT;

    return;
}

sub _store_unavailable ($decision) {
    return ( $decision->{denied_reason} || q{} ) eq $DENIED_STORE_UNAVAILABLE
      ? 1
      : 0;
}

sub _fail_closed_key ($input) {
    return join q{:},
      map { defined $_ ? $_ : q{} }
      ( $input->{scope}, $input->{actor_id}, $input->{action} );
}

sub _actor_hash ($input) {
    return sha256_hex( join q{:}, $input->{scope}, $input->{actor_id} || q{} );
}

sub _uuid_or_undef ($value) {
    return defined $value
      && $value =~
/\A [[:xdigit:]]{8} - [[:xdigit:]]{4} - [[:xdigit:]]{4} - [[:xdigit:]]{4} - [[:xdigit:]]{12} \z/msx
      ? $value
      : undef;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::RateLimiter - Shared rate limiting with an
explicit degradation policy.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $limiter = GPForum::Service::Operations::RateLimiter->new(
        degradation_policy =>
          GPForum::Service::Operations::RateLimiter::DegradationPolicy
          ->from_config($config),
        primary_store      => $postgresql_store,
        schema             => $schema,
        security_telemetry => $telemetry,
    );

    my $decision = $limiter->check(
        {
            action         => 'thread.create',
            actor_id       => $user_id,
            limit          => 30,
            scope          => 'forum_http',
            window_seconds => 60,
        }
    );

=head1 DESCRIPTION

Counts actions per scope, actor, and window. The authoritative counters live in
PostgreSQL through
L<GPForum::Service::Operations::RateLimiter::PostgreSQLStore> so that every
Hypnotoad worker shares one bucket.

=head2 Local memory is never cluster state

L<GPForum::Service::Operations::RateLimiter::LocalMemoryStore> counts inside a
single process only. Under N Hypnotoad workers it enforces the configured limit
N times over, once per worker, and it loses every bucket on restart. It is
therefore the authoritative store only when C<primary_store> is undefined,
which is the single-process development and unit-test wiring. Whenever
C<primary_store> is set, the local store is a degraded stand-in, never a source
of truth: decisions taken from it are flagged C<< degraded => 1 >>, they are
counted in C<< stats->{fallback_used} >>, and the snapshot reports them under a
C<fallback> key with C<< status => 'degraded' >>. Nothing in this class or its
callers may read a local bucket and present it as a cluster-wide count.

=head2 Degradation policy

When the authoritative store throws,
L<GPForum::Service::Operations::RateLimiter::DegradationPolicy> decides what
happens next:

=over

=item permissive

Serve from the local memory store and mark the decision degraded. Correct for
development, where one process handles all traffic.

=item fail_closed

Deny the request without touching the local store, so no per-process counter is
ever mistaken for cluster state and an attacker who can break the database
cannot buy an unlimited allowance. This is the default, and the mode
L</Bootstrap wiring> derives for staging and the production profiles.

=back

The policy applies only to real degradation. A limiter built without a
C<primary_store> keeps using the local store in both modes, because nothing has
degraded.

=head2 Decision contract

C<check> always returns a hash reference with C<ok>, C<key>, C<limit>,
C<remaining>, C<reset_at_epoch>, C<store>, C<window_seconds>,
C<observed_count>, and C<mitigation_hint>. Two further keys describe failure:

=over

=item C<degraded>

Present and true when the authoritative store was unavailable for this
decision, whichever mode is active.

=item C<denied_reason>

Present on every denial. C<over_limit> means the actor exceeded the configured
allowance and the count is real. C<store_unavailable> means the limiter denied
the request because it could not count authoritatively; C<observed_count> is
then the configured limit rather than a measurement, and C<store> is
C<unavailable>.

=back

=head2 Bootstrap wiring

L<GPForum::Bootstrap::Operations> builds the limiter with a policy derived from
C<< $config->environment >>. There is no dedicated configuration knob for the
mode; add a C<rate_limit_degradation_mode> accessor to L<GPForum::Config> and
L<GPForum::Service::Operations::RateLimiter::DegradationPolicy/from_config>
will prefer it without further changes.

=head1 SUBROUTINES/METHODS

=head2 check

Takes the limit input hash reference and returns the decision described in
L</Decision contract>. Records statistics, security telemetry, and, for
over-limit denials, an audit record.

=head2 snapshot

Returns the authoritative store snapshot merged with C<degradation_mode>,
C<fail_closed>, and a copy of C<stats>. When the authoritative snapshot throws,
the local snapshot is returned with C<< status => 'degraded' >> and
C<< fallback => 1 >> so the metrics endpoint cannot report a degraded limiter
as healthy.

=head1 DIAGNOSTICS

Telemetry separates the three interesting outcomes.
C<rate_limit_store_degraded> fires once per authoritative store failure.
C<rate_limit_fail_closed> fires only when a request is denied because the store
was unavailable. C<rate_limit_hit> fires for every denial and carries
C<reason>, matching C<denied_reason>.

The counters in C<stats> mirror that split: C<primary_failures> and
C<fallback_used> track degradation, while C<blocked> is the total of
C<blocked_over_limit> and C<blocked_degraded>.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read here. The degradation mode arrives as the
C<degradation_policy> attribute; see L</Bootstrap wiring>.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Digest::SHA>, L<Mojo::Base>,
L<GPForum::Infrastructure::EventRecorder>, and L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A fail-closed denial writes no audit record, because the audit trail uses the
same schema that just failed. Those denials are visible only through telemetry
and C<< stats->{blocked_degraded} >>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
