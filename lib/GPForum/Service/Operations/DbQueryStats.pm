# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DbQueryStats;

use strict;
use warnings;
use feature 'signatures';

use Const::Fast;
use parent      qw(DBIx::Class::Storage::Statistics);
use Time::HiRes qw(time);

our $VERSION = '0.001';

const my $DEFAULT_RECENT_LIMIT    => 25;
const my $FIRST_REPEAT            => 2;
const my $MILLISECONDS_PER_SECOND => 1_000;

sub new ( $class, @arguments ) {
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

sub attach_to_schema ( $self, $schema ) {
    return 0 if !$schema || !$schema->can('storage');

    my $storage = $schema->storage;
    return 0 if !$storage || !$storage->can('debugobj');

    $storage->debugobj($self);
    $storage->debug(1) if $storage->can('debug');
    $self->{attached} = 1;

    return 1;
}

sub start_request ( $self, $metadata ) {
    $self->{request_sequence}++;
    my $request = {
        request_id             => $self->{request_sequence},
        correlation_id         => $metadata->{correlation_id},
        route                  => $metadata->{route} || 'unknown',
        endpoint_name          => $metadata->{endpoint_name},
        status                 => undef,
        started_at             => time,
        duration_ms            => undef,
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

sub finish_request ( $self, $token, $metadata ) {
    my $request = $self->{current};
    my $undefined;
    return $undefined if !$request;

    $request->{route} = $metadata->{route}
      if defined $metadata->{route};
    $request->{endpoint_name} = $metadata->{endpoint_name}
      if defined $metadata->{endpoint_name};
    $request->{status} = $metadata->{status}
      if defined $metadata->{status};
    $request->{duration_ms} =
      int( ( time - $request->{started_at} ) * $MILLISECONDS_PER_SECOND );
    delete $request->{started_at};

    delete $request->{fingerprints};
    $self->_push_recent($request);
    $self->{current} = $token ? $token->{previous} : undef;

    return { %{$request} };
}

sub record_budget_observation ( $self, $request_id, $observation ) {
    my $undefined;
    return $undefined if !defined $request_id || !$observation;

    for my $request ( @{ $self->{recent_requests} } ) {
        next if $request->{request_id} != $request_id;
        $request->{query_budget_status}     = $observation->{status};
        $request->{query_budget}            = $observation->{budget};
        $request->{query_budget_observed}   = $observation->{observed};
        $request->{query_budget_violations} = $observation->{violations};
        return { %{$request} };
    }

    return $undefined;
}

sub last_request ($self) {
    my $undefined;
    return $undefined if !@{ $self->{recent_requests} };

    my $request = $self->{recent_requests}[-1];

    return { %{$request} };
}

sub snapshot ($self) {
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

sub txn_begin ($self) {
    $self->{total_transactions}++;
    $self->{current}{transactions}++ if $self->{current};

    return;
}

sub txn_commit {
    return;
}

# Everything DBIx::Class::Storage::Statistics would say goes through print:
# savepoints above all, which it writes to STDERR even when every other
# callback is overridden. With debug(1) on for the whole process, each nested
# transaction put "SAVEPOINT savepoint_0" in the production log. This object
# counts; it never writes.
## no critic (Subroutines::ProhibitBuiltinHomonyms)
sub print {
    return;
}
## use critic

sub txn_rollback {
    return;
}

# DBIx::Class calls this as query_start($sql, @bind), so the binds are accepted
# and ignored: the fingerprint is the statement, not its values. A two-argument
# signature made every query that had a bind value die inside DBI.
sub query_start ( $self, $sql, @ ) {
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

sub _push_recent ( $self, $request ) {
    push @{ $self->{recent_requests} }, { %{$request} };
    while ( @{ $self->{recent_requests} } > $self->{recent_limit} ) {
        shift @{ $self->{recent_requests} };
    }

    return;
}

sub _fingerprint ($sql) {
    $sql = defined $sql ? $sql : q{};
    $sql =~ s/\s+/ /gmsx;
    $sql =~ s/\A \s+//msx;
    $sql =~ s/\s+ \z//msx;

    return $sql;
}

sub _sum ( $rows, $column ) {
    my $sum = 0;
    for my $row ( @{$rows} ) {
        $sum += $row->{$column} || 0;
    }

    return $sum;
}

sub _budget_mismatches ($rows) {
    my $count = 0;
    for my $row ( @{$rows} ) {
        $count++ if ( $row->{query_budget_status} || q{} ) eq 'fail';
    }

    return $count;
}

1;
