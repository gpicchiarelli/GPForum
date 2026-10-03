# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DeadLetterCheck;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);
use GPForum::Service::Outbox::Dispatcher;

our $VERSION = '0.001';

const my $EXIT_FAILURE    => 1;
const my $STATUS_PASS     => 'pass';
const my $STATUS_FAIL     => 'fail';
const my $PROBE_OUTBOX_ID => 'dead-letter-check-probe';
const my $PROBE_EVENT_ID  => 'dead-letter-check-event';
const my $RESIDUAL_BETA =>
  'This dead-letter check does not claim private-beta readiness by itself.';
const my $RESIDUAL_LIVE =>
'Live staging still needs operator confirmation that /admin/jobs shows the review row and that SMTP/TLS/deploy residuals remain separate.';
const my $RESIDUAL_SIM =>
'Simulate mode uses an in-memory outbox stack; archive a --live run against staging PostgreSQL before treating dead-letter ops as closed.';
const my %VALID_MODE => map { $_ => 1 } qw(dry_run simulate);

has dispatcher_factory => undef;

sub run ( $self, $options ) {
    $options ||= {};
    my $mode = $options->{mode} // 'simulate';
    croak "Unsupported dead-letter-check mode: $mode"
      if !$VALID_MODE{$mode};

    my $evidence = eval { return $self->_run_mode( $mode, $options ) };
    if ( !$evidence ) {
        return evidence_finalize(
            {
                check         => 'dead_letter_check',
                status        => $STATUS_FAIL,
                mode          => $mode,
                error         => _trim($EVAL_ERROR),
                residual_gaps =>
                  [ $RESIDUAL_BETA, $RESIDUAL_LIVE, $RESIDUAL_SIM ],
            }
        );
    }

    return evidence_finalize($evidence);
}

sub format_evidence ( $self, $evidence, $format ) {
    $evidence = evidence_finalize( $evidence // {} );
    $format ||= 'json';
    return $self->human_text($evidence) if $format eq 'human';

    return encode_json($evidence) . "\n";
}

sub human_text ( $self, $evidence ) {
    my @lines = (
        'dead-letter-check status=' . ( $evidence->{status} // 'fail' ),
        'mode=' .                     ( $evidence->{mode}   // 'unknown' ),
    );
    for my $step ( @{ $evidence->{steps} // [] } ) {
        push @lines, 'step ' . $step->{name} . '=' . $step->{status};
    }
    if ( _has_text( $evidence->{error} ) ) {
        push @lines, 'error=' . $evidence->{error};
    }
    for my $gap ( @{ $evidence->{residual_gaps} // [] } ) {
        push @lines, "residual: $gap";
    }

    return join( "\n", @lines ) . "\n";
}

sub exit_status ( $self, $evidence ) {
    return 0 if ( $evidence->{status} // q{} ) eq $STATUS_PASS;

    return $EXIT_FAILURE;
}

sub _run_mode ( $self, $mode, $options ) {
    return $self->_dry_run_evidence if $mode eq 'dry_run';

    return $self->_simulate($options);
}

sub _dry_run_evidence {
    return {
        check  => 'dead_letter_check',
        status => $STATUS_PASS,
        mode   => 'dry_run',
        plan   => {
            steps => [
                'force_permanent_failure',
                'assert_dead_letter_and_cancelled',
                'redispatch_selected_zero',
                'fresh_row_survives_retention_cutoff',
            ],
        },
        residual_gaps => [ $RESIDUAL_BETA, $RESIDUAL_LIVE, $RESIDUAL_SIM ],
    };
}

sub _simulate ( $self, $options ) {
    my $stack         = $self->_simulate_stack($options);
    my $first         = $stack->{dispatcher}->dispatch_pending(1);
    my $letter_count  = scalar @{ $stack->{dead_letters}->created };
    my $outbox_status = $stack->{message}->get_column('status') // q{};
    my $failure_type =
      ( $stack->{dead_letters}->created->[0]{failure_type} // q{} );

    my @steps = (
        {
            name   => 'force_permanent_failure',
            status => (
                     ( $first->{dead_lettered} // 0 ) == 1
                  && ( $first->{failed} // 0 ) == 0
            ) ? $STATUS_PASS : $STATUS_FAIL,
            summary => $first,
        },
        {
            name   => 'assert_dead_letter_and_cancelled',
            status => (
                     $letter_count == 1
                  && $outbox_status eq 'cancelled'
                  && $failure_type eq 'permanent'
            ) ? $STATUS_PASS : $STATUS_FAIL,
            dead_letters  => $letter_count,
            outbox_status => $outbox_status,
            failure_type  => $failure_type,
        },
    );

    my $second = $stack->{dispatcher}->dispatch_pending(1);
    push @steps,
      {
        name   => 'redispatch_selected_zero',
        status => ( ( $second->{selected} // -1 ) == 0 )
        ? $STATUS_PASS
        : $STATUS_FAIL,
        summary => $second,
      };

    my $purged =
      $stack->{dead_letters}->purge_older_than('2020-01-01T00:00:00Z');
    my $remaining = scalar @{ $stack->{dead_letters}->created };
    push @steps,
      {
        name   => 'fresh_row_survives_retention_cutoff',
        status => ( $purged == 0 && $remaining == 1 )
        ? $STATUS_PASS
        : $STATUS_FAIL,
        purged    => $purged,
        remaining => $remaining,
        note      =>
'Cutoff in the past must not delete a fresh dead-letter (retention hold).',
      };

    my $status =
      ( grep { $_->{status} ne $STATUS_PASS } @steps )
      ? $STATUS_FAIL
      : $STATUS_PASS;

    return {
        check         => 'dead_letter_check',
        status        => $status,
        mode          => 'simulate',
        steps         => \@steps,
        residual_gaps => [ $RESIDUAL_BETA, $RESIDUAL_LIVE, $RESIDUAL_SIM ],
    };
}

sub _simulate_stack ( $self, $options ) {
    if ( $self->dispatcher_factory ) {
        return $self->dispatcher_factory->($options);
    }

    my $message = GPForum::Service::Operations::DeadLetterCheck::ProbeRow->new(
        data => {
            outbox_id       => $PROBE_OUTBOX_ID,
            attempt_count   => 0,
            status          => 'pending',
            next_attempt_at => '0000-01-01T00:00:00Z',
            created_at      => '0000-01-01T00:00:00Z',
            payload         => { event_id => $PROBE_EVENT_ID },
        }
    );
    my $outbox =
      GPForum::Service::Operations::DeadLetterCheck::ProbeOutbox->new(
        rows => [$message], );
    my $letters =
      GPForum::Service::Operations::DeadLetterCheck::ProbeLetters->new;
    my $schema =
      GPForum::Service::Operations::DeadLetterCheck::ProbeSchema->new(
        outbox_resultset      => $outbox,
        dead_letter_resultset => $letters,
      );
    my $transport =
      GPForum::Service::Operations::DeadLetterCheck::ProbeTransport->new(
        fail_ids   => { $PROBE_OUTBOX_ID => 1 },
        fail_types => { $PROBE_OUTBOX_ID => 'permanent' },
      );
    my $dispatcher = GPForum::Service::Outbox::Dispatcher->new(
        schema    => $schema,
        transport => $transport,
        clock => GPForum::Service::Operations::DeadLetterCheck::ProbeClock->new,
        id_service =>
          GPForum::Service::Operations::DeadLetterCheck::ProbeId->new,
        worker_id    => 'dead-letter-check',
        max_attempts => 5,
    );

    return {
        dispatcher   => $dispatcher,
        dead_letters => $letters,
        message      => $message,
    };
}

sub _trim ($error) {
    $error = "$error";
    $error =~ s/\s+\z//msx;

    return $error;
}

sub _has_text ($value) {
    return defined $value && length $value;
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeFailure;

use overload q{""} => sub { return $_[0]->{message} }, fallback => 1;

sub new ( $class, $message, $failure_type ) {
    return bless {
        message      => $message // 'probe failure',
        failure_type => $failure_type,
    }, $class;
}

sub throw ( $class, $message, $failure_type ) {
    die $class->new( $message, $failure_type );
}

sub failure_type ($self) {
    return $self->{failure_type};
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeTransport;

use Mojo::Base -base;
use v5.40;

has fail_ids   => sub { return {}; };
has fail_types => sub { return {}; };

sub dispatch ( $self, $message ) {
    my $outbox_id = $message->get_column('outbox_id');
    if ( $self->fail_ids->{$outbox_id} ) {
        GPForum::Service::Operations::DeadLetterCheck::ProbeFailure->throw(
            'dead-letter-check permanent probe',
            $self->fail_types->{$outbox_id}
        );
    }

    return;
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeRow;

use Mojo::Base -base;
use v5.40;

has data    => sub { return {}; };
has updates => sub { return []; };

sub update ( $self, $changes ) {
    push @{ $self->updates }, $changes;
    for my $key ( keys %{$changes} ) {
        $self->data->{$key} = $changes->{$key};
    }

    return $self;
}

sub get_column ( $self, $column ) {
    return $self->data->{$column};
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeSearch;

use Mojo::Base -base;
use v5.40;

has rows => sub { return []; };

sub all ($self) {
    return @{ $self->rows };
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeOutbox;

use Mojo::Base -base;
use v5.40;

has rows => sub { return []; };

sub search_rs ( $self, $query, $attrs ) {
    my @matched = grep { _row_matches( $_, $query ) } @{ $self->rows };
    my $limit   = $attrs->{rows};
    if ( defined $limit && $limit < @matched ) {
        @matched = @matched[ 0 .. $limit - 1 ];
    }

    return GPForum::Service::Operations::DeadLetterCheck::ProbeSearch->new(
        rows => \@matched, );
}

sub _row_matches ( $row, $query ) {
    return 1 if !defined $query;
    if ( ref $query eq 'ARRAY' ) {
        for my $condition ( @{$query} ) {
            return 1 if _row_matches( $row, $condition );
        }
        return 0;
    }

    for my $column ( keys %{$query} ) {
        my $expected = $query->{$column};
        my $actual   = $row->get_column($column);
        if ( ref $expected eq 'HASH' && exists $expected->{-in} ) {
            my %ok = map { $_ => 1 } @{ $expected->{-in} };
            return 0 if !$ok{ $actual // q{} };
            next;
        }
        if ( ref $expected eq 'HASH' && exists $expected->{'<='} ) {
            return 0
              if !defined $actual || $actual gt $expected->{'<='};
            next;
        }
        return 0 if ( $actual // q{} ) ne ( $expected // q{} );
    }

    return 1;
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeLetters;

use Mojo::Base -base;
use v5.40;

has created => sub { return []; };
has rows    => sub { return {}; };

sub create ( $self, $row ) {
    my $key = join q{:}, $row->{source_table} // q{}, $row->{source_id} // q{};
    $self->rows->{$key} = $row;
    push @{ $self->created }, $row;

    return $row;
}

sub find ( $self, $query ) {
    my $key = join q{:}, $query->{source_table} // q{},
      $query->{source_id} // q{};

    return $self->rows->{$key};
}

sub purge_older_than ( $self, $cutoff ) {
    my @kept;
    my $purged = 0;
    for my $row ( @{ $self->created } ) {
        my $stamp = $row->{last_failed_at} // q{};
        if ( length $stamp && $stamp lt $cutoff ) {
            $purged++;
            next;
        }
        push @kept, $row;
    }
    $self->created( \@kept );
    $self->rows(
        {
            map {
                ( join q{:}, $_->{source_table} // q{},
                    $_->{source_id} // q{} ) => $_
            } @kept
        }
    );

    return $purged;
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeSchema;

use Mojo::Base -base;
use v5.40;

has outbox_resultset      => undef;
has dead_letter_resultset => undef;

sub resultset ( $self, $name ) {
    return $self->outbox_resultset      if $name eq 'OutboxMessage';
    return $self->dead_letter_resultset if $name eq 'DeadLetter';

    return undef;
}

sub txn_do ( $self, $code ) {
    return $code->();
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeClock;

use Mojo::Base -base;
use v5.40;

sub now_iso8601 {
    return '2026-09-21T12:00:00Z';
}

sub epoch_plus_iso8601 ( $self, $seconds ) {
    return '2026-09-21T12:01:00Z' if $seconds;
    return '2026-09-21T12:00:00Z';
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeId;

use Mojo::Base -base;
use v5.40;

has counter => 0;

sub uuid ($self) {
    $self->counter( $self->counter + 1 );

    return sprintf 'dead-letter-id-%d', $self->counter;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::DeadLetterCheck - Operator dead-letter staging check.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $report = GPForum::Service::Operations::DeadLetterCheck->new->run(
        { mode => 'simulate' }
    );

=head1 DESCRIPTION

Automates the staging check in F<docs/ops/dead-letters.md> against an
in-memory dispatcher stack (C<simulate>) or prints the plan (C<dry_run>).
Emits EvidenceMeta JSON. Does not claim private-beta readiness. This module
has no live mode: a C<--live> run against staging PostgreSQL remains a
residual gap.

The other packages in this file are the in-memory stand-ins of the
C<simulate> stack, built only by L</run>: C<ProbeFailure>,
C<ProbeTransport>, C<ProbeRow>, C<ProbeSearch>, C<ProbeOutbox>,
C<ProbeLetters>, C<ProbeSchema>, C<ProbeClock> and C<ProbeId>, all under
C<GPForum::Service::Operations::DeadLetterCheck::>. The real
L<GPForum::Service::Outbox::Dispatcher> and its collaborators call most of
their methods as the schema, row, clock, id and transport interfaces; they
are listed after the module's own methods.

=head1 SUBROUTINES/METHODS

=head2 run

Takes C<< { mode => $mode } >>: C<simulate> (the default) or C<dry_run>.
C<dry_run> returns C<pass> with the plan of four steps. C<simulate> builds
the stack -- from C<dispatcher_factory> when set, otherwise one pending
outbox row whose delivery fails permanently, behind a dispatcher allowed five
attempts -- and runs the steps:

=over 4

=item force_permanent_failure

The first C<dispatch_pending(1)> dead-letters the row and reports no plain
failure.

=item assert_dead_letter_and_cancelled

There is exactly one dead letter, of failure type C<permanent>, and the
outbox row is C<cancelled>.

=item redispatch_selected_zero

A second dispatch selects nothing.

=item fresh_row_survives_retention_cutoff

Purging with a cutoff in the past deletes nothing: the fresh dead letter is
kept.

=back

The status is C<pass> when every step passes, otherwise C<fail>; an
exception during the run gives C<fail> with its message in C<error>. The
result goes through C<evidence_finalize> from
L<GPForum::Service::Operations::EvidenceMeta>, which marks it redacted, sets
C<private_beta_claimed> to 0 and de-duplicates C<residual_gaps>.

C<dispatcher_factory>, when given, is called with the options and must return
C<< { dispatcher, dead_letters, message } >>: a dispatcher with
C<dispatch_pending>, a dead-letter store with C<created> and
C<purge_older_than>, and the outbox row with C<get_column>.

=head2 format_evidence

Takes the evidence and a format, finalizes the evidence again, and returns
L</human_text> for C<human> and one line of JSON for anything else (C<json>
is the default).

=head2 human_text

Returns the evidence as text: the status, the mode, a line per step, the
error when there is one, and a line per residual gap.

=head2 exit_status

Returns 0 when the status is C<pass>, otherwise 1.

=head2 new (ProbeFailure)

C<< ProbeFailure->new( $message, $failure_type ) >>: an exception object
that stringifies to its message (C<probe failure> when none is given).

=head2 throw (ProbeFailure)

C<< ProbeFailure->throw( $message, $failure_type ) >>: dies with a new
probe failure.

=head2 failure_type (ProbeFailure)

Returns the declared failure type. L<GPForum::Service::Outbox::FailureType>
uses a declared type before it falls back to matching the message.

=head2 dispatch (ProbeTransport)

Takes an outbox row. For a C<outbox_id> listed in C<fail_ids>, throws a probe
failure of the type in C<fail_types>; otherwise returns nothing.

=head2 update (ProbeRow)

Records the changes in C<updates>, applies them to C<data>, and returns the
row.

=head2 get_column (ProbeRow)

Returns the column's value from C<data>.

=head2 all (ProbeSearch)

Returns the matched rows as a list.

=head2 search_rs (ProbeOutbox)

Takes a condition and attributes and returns a C<ProbeSearch> of the rows
that match, at most C<< $attrs->{rows} >> of them. It understands only what
the dispatcher's claim query uses: equality, C<-in>, C<< <= >> (as a string
comparison) and an array reference of alternatives. C<order_by> is ignored.

=head2 create (ProbeLetters)

Stores a dead-letter row under its C<source_table> and C<source_id>,
appends it to C<created>, and returns it.

=head2 find (ProbeLetters)

Returns the row stored for a C<source_table> and C<source_id>, or C<undef>.

=head2 purge_older_than (ProbeLetters)

Removes the rows whose C<last_failed_at> is set and sorts before the cutoff,
and returns how many it removed.

=head2 resultset (ProbeSchema)

Returns the probe outbox for C<OutboxMessage>, the probe letters for
C<DeadLetter>, and C<undef> for any other name.

=head2 txn_do (ProbeSchema)

Runs the code and returns its result; there is no transaction.

=head2 now_iso8601 (ProbeClock)

Returns the fixed time C<2026-09-21T12:00:00Z>.

=head2 epoch_plus_iso8601 (ProbeClock)

Returns C<2026-09-21T12:01:00Z> for any non-zero number of seconds, and the
fixed time otherwise.

=head2 uuid (ProbeId)

Returns C<dead-letter-id-1>, C<dead-letter-id-2>, and so on.

=head1 DIAGNOSTICS

L</run> croaks C<Unsupported dead-letter-check mode: $mode> for any mode
other than C<simulate> and C<dry_run>. Any other error during a run is
reported as C<fail> evidence with an C<error>, not thrown.

=head1 CONFIGURATION AND ENVIRONMENT

None. Simulate mode runs in memory and touches no database.

=head1 DEPENDENCIES

L<GPForum::Service::Outbox::Dispatcher>,
L<GPForum::Service::Operations::EvidenceMeta>,
L<JSON::MaybeXS>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Simulate mode runs the real dispatcher against stand-ins, not PostgreSQL:
the dispatcher takes its portable claim path rather than the PostgreSQL one,
and the retention step exercises the probe's own C<purge_older_than>. There
is no live mode.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
