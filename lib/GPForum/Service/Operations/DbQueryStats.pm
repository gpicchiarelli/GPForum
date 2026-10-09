# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DbQueryStats;

use v5.40;

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
        connection_actions => {
            map { _fingerprint($_) => 1 }
              @{ $arguments{connection_actions} || [] }
        },
        current          => undef,
        recent_limit     => $arguments{recent_limit} || $DEFAULT_RECENT_LIMIT,
        recent_requests  => [],
        request_sequence => 0,
        total_connection_queries => 0,
        total_queries            => 0,
        total_transactions       => 0,
    }, $class;
}

sub attach_to_schema ( $self, $schema ) {
    return 0 if !$schema || !$schema->can('storage');

    my $storage = $schema->storage;
    return 0 if !$storage || !$storage->can('debugobj');

    $storage->debugobj($self);
    if ( $storage->can('debug') ) {
        $storage->debug(1);
    }
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
        connection_queries     => 0,
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
    return undef if !$request;

    for my $field (qw(route endpoint_name status)) {
        if ( defined $metadata->{$field} ) {
            $request->{$field} = $metadata->{$field};
        }
    }
    $request->{duration_ms} =
      int( ( time - $request->{started_at} ) * $MILLISECONDS_PER_SECOND );
    delete $request->{started_at};

    delete $request->{fingerprints};
    $self->_push_recent($request);
    $self->{current} = $token ? $token->{previous} : undef;

    return { %{$request} };
}

sub record_budget_observation ( $self, $request_id, $observation ) {
    return undef if !defined $request_id || !$observation;

    for my $request ( @{ $self->{recent_requests} } ) {
        next if $request->{request_id} != $request_id;
        $request->{query_budget_status}     = $observation->{status};
        $request->{query_budget}            = $observation->{budget};
        $request->{query_budget_observed}   = $observation->{observed};
        $request->{query_budget_violations} = $observation->{violations};
        return { %{$request} };
    }

    return undef;
}

sub last_request ($self) {
    return undef if !@{ $self->{recent_requests} };

    my $request = $self->{recent_requests}[-1];

    return { %{$request} };
}

sub snapshot ($self) {
    my @recent = map { +{ %{$_} } } @{ $self->{recent_requests} };

    return {
        attached                 => $self->{attached} ? 1 : 0,
        requests_observed        => scalar @recent,
        total_queries            => $self->{total_queries},
        total_connection_queries => $self->{total_connection_queries},
        total_transactions       => $self->{total_transactions},
        duplicate_query_warnings => _sum( \@recent, 'duplicate_queries' ),
        query_budget_mismatches  => _budget_mismatches( \@recent ),
        last_request             => scalar $self->last_request,
        recent_requests          => \@recent,
    };
}

sub txn_begin ($self) {
    $self->{total_transactions}++;
    if ( $self->{current} ) {
        $self->{current}{transactions}++;
    }

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
# A statement a connection runs when it is made (Config's session settings)
# is the connection's, not the request's that happened to make it: it is
# counted apart, and does not touch the request's budget.
sub query_start ( $self, $sql, @ ) {
    my $fingerprint = _fingerprint($sql);
    if ( $self->{connection_actions}{$fingerprint} ) {
        $self->{total_connection_queries}++;
        if ( $self->{current} ) {
            $self->{current}{connection_queries}++;
        }
        return;
    }

    $self->{total_queries}++;
    return if !$self->{current};

    $self->{current}{queries}++;
    my $count = ++$self->{current}{fingerprints}{$fingerprint};
    if ( $count >= $FIRST_REPEAT ) {
        $self->{current}{duplicate_queries}++;
        if ( $count == $FIRST_REPEAT ) {
            push @{ $self->{current}{duplicate_fingerprints} }, $fingerprint;
        }
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
    return
      scalar grep { ( $_->{query_budget_status} || q{} ) eq 'fail' } @{$rows};
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::DbQueryStats - Count the queries, transactions and repeated statements of each request.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $stats = GPForum::Service::Operations::DbQueryStats->new(
        recent_limit => 25,
    );
    $stats->attach_to_schema($schema);

    my $token = $stats->start_request(
        { correlation_id => $request_id, route => '/t/42/slug' } );
    # ... the request runs its queries ...
    my $request = $stats->finish_request( $token,
        { route => 'thread_show', endpoint_name => 'thread_show', status => 200 }
    );
    $stats->record_budget_observation( $request->{request_id}, $observation );

    my $snapshot = $stats->snapshot;

=head1 DESCRIPTION

A L<DBIx::Class::Storage::Statistics> subclass installed as the schema
storage's C<debugobj>. DBIx::Class calls it for every statement and every
transaction; it counts them per request, process-wide, and flags a
statement that runs more than once in the same request (the same SQL text
with whitespace collapsed, whatever its bind values), which is how an N+1
query shows up. The application keeps one instance; its C<before_dispatch>
and C<after_dispatch> hooks open and close the request, and the query
budget check compares the counts with the endpoint's budget.

It only counts. Every callback that the parent class would turn into log
output, savepoints included, is overridden to do nothing, so turning
C<debug> on for the whole process writes nothing to the log.

Finished requests are kept in a bounded list of recent requests (25 by
default), oldest dropped first.

=head1 SUBROUTINES/METHODS

=head2 new

Class method. Takes C<recent_limit> as a key/value pair or in a hash
reference; a missing or zero limit means 25. Takes C<connection_actions>,
an array reference of the statements a connection runs when it is made
(L<GPForum::Config/database_session_settings>): these are counted as the
connection's, C<connection_queries> on the request and
C<total_connection_queries> overall, never as the request's queries.
Returns a detached collector with no requests.

=head2 attach_to_schema

Takes a schema. Installs the collector as its storage's C<debugobj> and
turns C<debug> on. Returns 1, or 0 (changing nothing) when the schema has
no storage or the storage has no C<debugobj>.

=head2 start_request

Takes a hash reference with C<correlation_id>, C<route> (C<unknown> when
absent) and C<endpoint_name>. Makes a new request current, numbered by a
sequence local to the collector, and returns a token that remembers the
request that was current before it.

=head2 finish_request

Takes the token from L</start_request> and a hash reference whose
C<route>, C<endpoint_name> and C<status>, when defined, overwrite the
request's. Sets C<duration_ms>, adds the request to the recent list,
restores the request the token remembers as current (none without a
token) and returns a copy of the finished request: C<request_id>,
C<correlation_id>, C<route>, C<endpoint_name>, C<status>, C<duration_ms>,
C<queries>, C<transactions>, C<duplicate_queries>,
C<duplicate_fingerprints> and C<attached>. Returns C<undef> when no request
is current.

=head2 record_budget_observation

Takes a request id and a query budget observation (C<status>, C<budget>,
C<observed>, C<violations>). Stores them on that recent request as
C<query_budget_status>, C<query_budget>, C<query_budget_observed> and
C<query_budget_violations> and returns a copy of the request. Returns
C<undef> when the id is undefined, the observation is false or the request
is no longer in the recent list.

=head2 last_request

Returns a copy of the most recently finished request, or C<undef> when
there is none.

=head2 snapshot

Returns a hash reference with C<attached>, C<requests_observed> (the size
of the recent list), C<total_queries> and C<total_transactions> since the
collector was made, C<duplicate_query_warnings> (the repeated statements
summed over the recent list), C<query_budget_mismatches> (recent requests
whose budget status is C<fail>), C<last_request> and C<recent_requests>
(copies, oldest first).

=head2 query_start

DBIx::Class callback, called with the SQL and its bind values. Counts the
statement in the process total and, when a request is current, in the
request. The second time a statement is seen in a request its text is added
to C<duplicate_fingerprints>; every repeat adds one to
C<duplicate_queries>. Returns nothing.

=head2 query_end

DBIx::Class callback; does nothing.

=head2 txn_begin

DBIx::Class callback. Counts a transaction in the process total and in the
current request, if any. Returns nothing.

=head2 txn_commit

DBIx::Class callback; does nothing.

=head2 txn_rollback

DBIx::Class callback; does nothing.

=head2 print

Overrides the parent's output method, which would otherwise write
savepoint statements to STDERR; does nothing.

=head1 DIAGNOSTICS

None. Missing requests and tokens are answered with C<undef> or ignored.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<DBIx::Class::Storage::Statistics>, L<Time::HiRes>, L<Const::Fast>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
