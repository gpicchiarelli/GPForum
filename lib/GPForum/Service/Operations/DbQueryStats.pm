package GPForum::Service::Operations::DbQueryStats;

use strict;
use warnings;

use Const::Fast;
use parent qw(DBIx::Class::Storage::Statistics);

our $VERSION = '0.001';

const my $DEFAULT_RECENT_LIMIT => 25;
const my $FIRST_REPEAT         => 2;

sub new {
    my ( $class, @arguments ) = @_;

    my %arguments =
      @arguments == 1 && ref $arguments[0] eq 'HASH'
      ? %{ $arguments[0] }
      : @arguments;

    return bless {
        attached           => 0,
        current            => undef,
        recent_limit       => $arguments{recent_limit} || $DEFAULT_RECENT_LIMIT,
        recent_requests    => [],
        request_sequence   => 0,
        total_queries      => 0,
        total_transactions => 0,
    }, $class;
}

sub attach_to_schema {
    my ( $self, $schema ) = @_;

    return 0 if !$schema || !$schema->can('storage');

    my $storage = $schema->storage;
    return 0 if !$storage || !$storage->can('debugobj');

    $storage->debugobj($self);
    $storage->debug(1) if $storage->can('debug');
    $self->{attached} = 1;

    return 1;
}

sub start_request {
    my ( $self, $metadata ) = @_;

    $self->{request_sequence}++;
    my $request = {
        request_id             => $self->{request_sequence},
        route                  => $metadata->{route} || 'unknown',
        endpoint_name          => $metadata->{endpoint_name},
        status                 => undef,
        queries                => 0,
        transactions           => 0,
        duplicate_queries      => 0,
        duplicate_fingerprints => [],
        fingerprints           => {},
        attached               => $self->{attached} ? 1 : 0,
    };
    my $token = {
        request_id => $request->{request_id},
        previous   => $self->{current},
    };
    $self->{current} = $request;

    return $token;
}

sub finish_request {
    my ( $self, $token, $metadata ) = @_;

    my $request = $self->{current};
    return if !$request;

    $request->{route} = $metadata->{route}
      if defined $metadata->{route};
    $request->{endpoint_name} = $metadata->{endpoint_name}
      if defined $metadata->{endpoint_name};
    $request->{status} = $metadata->{status}
      if defined $metadata->{status};

    delete $request->{fingerprints};
    $self->_push_recent($request);
    $self->{current} = $token ? $token->{previous} : undef;

    return { %{$request} };
}

sub record_budget_observation {
    my ( $self, $request_id, $observation ) = @_;

    return if !defined $request_id || !$observation;

    for my $request ( @{ $self->{recent_requests} } ) {
        next if $request->{request_id} != $request_id;
        $request->{query_budget_status}     = $observation->{status};
        $request->{query_budget}            = $observation->{budget};
        $request->{query_budget_observed}   = $observation->{observed};
        $request->{query_budget_violations} = $observation->{violations};
        return { %{$request} };
    }

    return;
}

sub last_request {
    my ($self) = @_;

    return if !@{ $self->{recent_requests} };

    my $request = $self->{recent_requests}[-1];

    return { %{$request} };
}

sub snapshot {
    my ($self) = @_;

    my @recent = map {
        { %{$_} }
    } @{ $self->{recent_requests} };

    return {
        attached                 => $self->{attached} ? 1 : 0,
        requests_observed        => scalar @recent,
        total_queries            => $self->{total_queries},
        total_transactions       => $self->{total_transactions},
        duplicate_query_warnings => _sum( \@recent, 'duplicate_queries' ),
        query_budget_mismatches  => _budget_mismatches( \@recent ),
        last_request             => scalar $self->last_request,
        recent_requests          => \@recent,
    };
}

sub txn_begin {
    my ($self) = @_;

    $self->{total_transactions}++;
    $self->{current}{transactions}++ if $self->{current};

    return;
}

sub txn_commit {
    return;
}

sub txn_rollback {
    return;
}

sub query_start {
    my ( $self, $sql ) = @_;

    $self->{total_queries}++;
    return if !$self->{current};

    $self->{current}{queries}++;
    my $fingerprint = _fingerprint($sql);
    my $count       = ++$self->{current}{fingerprints}{$fingerprint};
    if ( $count >= $FIRST_REPEAT ) {
        $self->{current}{duplicate_queries}++;
        push @{ $self->{current}{duplicate_fingerprints} }, $fingerprint
          if $count == $FIRST_REPEAT;
    }

    return;
}

sub query_end {
    return;
}

sub _push_recent {
    my ( $self, $request ) = @_;

    push @{ $self->{recent_requests} }, { %{$request} };
    while ( @{ $self->{recent_requests} } > $self->{recent_limit} ) {
        shift @{ $self->{recent_requests} };
    }

    return;
}

sub _fingerprint {
    my ($sql) = @_;

    $sql = defined $sql ? $sql : q{};
    $sql =~ s/\s+/ /gmsx;
    $sql =~ s/\A \s+//msx;
    $sql =~ s/\s+ \z//msx;

    return $sql;
}

sub _sum {
    my ( $rows, $column ) = @_;

    my $sum = 0;
    for my $row ( @{$rows} ) {
        $sum += $row->{$column} || 0;
    }

    return $sum;
}

sub _budget_mismatches {
    my ($rows) = @_;

    my $count = 0;
    for my $row ( @{$rows} ) {
        $count++ if ( $row->{query_budget_status} || q{} ) eq 'fail';
    }

    return $count;
}

1;
