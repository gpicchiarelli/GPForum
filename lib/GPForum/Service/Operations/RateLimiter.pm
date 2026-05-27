package GPForum::Service::Operations::RateLimiter;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;
use GPForum::Service::Operations::RateLimiter::LocalMemoryStore;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;

has clock          => sub { return GPForum::Service::Clock->new; };
has fallback_store => sub {
    my ($self) = @_;

    return GPForum::Service::Operations::RateLimiter::LocalMemoryStore->new(
        clock => $self->clock, );
};
has id_service         => sub { return GPForum::Service::Id->new; };
has primary_store      => undef;
has schema             => undef;
has security_telemetry => undef;
has stats              => sub {
    return {
        allowed          => 0,
        audit_failures   => 0,
        blocked          => 0,
        checks           => 0,
        fallback_used    => 0,
        primary_failures => 0,
    };
};

sub check {
    my ( $self, $input ) = @_;

    my $decision = $self->_check_primary($input);
    if ( !$decision ) {
        $decision = $self->_check_fallback($input);
    }

    $self->_record_decision( $input, $decision );

    return $decision;
}

sub snapshot {
    my ($self) = @_;

    my $store_snapshot = $self->_store_snapshot;

    return { %{$store_snapshot}, stats => { %{ $self->stats } }, };
}

sub _check_primary {
    my ( $self, $input ) = @_;

    return if !$self->primary_store;

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
        return;
    }

    return $decision;
}

sub _check_fallback {
    my ( $self, $input ) = @_;

    my $decision = $self->fallback_store->check($input);
    if ( $self->primary_store ) {
        $decision->{degraded} = 1;
        $self->stats->{fallback_used} += 1;
    }

    return $decision;
}

sub _record_decision {
    my ( $self, $input, $decision ) = @_;

    $self->stats->{checks} += 1;
    if ( $decision->{ok} ) {
        $self->stats->{allowed} += 1;
        return;
    }

    $self->stats->{blocked} += 1;
    $self->_telemetry(
        'rate_limit_hit',
        {
            action   => $input->{action},
            degraded => $decision->{degraded} ? 1 : 0,
            status   => 429,
            store    => $decision->{store},
        },
    );
    $self->_record_block_audit( $input, $decision );

    return;
}

sub _record_block_audit {
    my ( $self, $input, $decision ) = @_;

    return if !$self->schema;

    my $created = eval {
        return $self->schema->resultset('AuditLog')->create(
            {
                action         => 'rate_limit.blocked',
                actor_id       => _uuid_or_undef( $input->{actor_id} ),
                audit_id       => $self->id_service->uuid,
                correlation_id => $self->id_service->uuid,
                created_at     => $self->clock->now_iso8601,
                metadata       => {
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
            }
        );
    };

    if ( !$created ) {
        $self->stats->{audit_failures} += 1;
    }

    return;
}

sub _store_snapshot {
    my ($self) = @_;

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

sub _telemetry {
    my ( $self, $event_type, $metadata ) = @_;

    return if !$self->security_telemetry;

    return $self->security_telemetry->record( $event_type, $metadata );
}

sub _actor_hash {
    my ($input) = @_;

    return sha256_hex( join q{:}, $input->{scope}, $input->{actor_id} || q{} );
}

sub _uuid_or_undef {
    my ($value) = @_;

    return defined $value
      && $value =~
/\A [[:xdigit:]]{8} - [[:xdigit:]]{4} - [[:xdigit:]]{4} - [[:xdigit:]]{4} - [[:xdigit:]]{12} \z/msx
      ? $value
      : undef;
}

1;
