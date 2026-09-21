package GPForum::Service::Operations::DeadLetterCheck;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base;

use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);
use GPForum::Service::Outbox::Dispatcher;

our $VERSION = '0.001';

const my $EXIT_FAILURE     => 1;
const my $STATUS_PASS      => 'pass';
const my $STATUS_FAIL      => 'fail';
const my $PROBE_OUTBOX_ID  => 'dead-letter-check-probe';
const my $PROBE_EVENT_ID   => 'dead-letter-check-event';
const my $RESIDUAL_BETA    =>
  'This dead-letter check does not claim private-beta readiness by itself.';
const my $RESIDUAL_LIVE =>
'Live staging still needs operator confirmation that /admin/jobs shows the review row and that SMTP/TLS/deploy residuals remain separate.';
const my $RESIDUAL_SIM =>
'Simulate mode uses an in-memory outbox stack; archive a --live run against staging PostgreSQL before treating dead-letter ops as closed.';
const my %VALID_MODE => map { $_ => 1 } qw(dry_run simulate);

has dispatcher_factory => undef;

sub run {
    my ( $self, $options ) = @_;

    $options ||= {};
    my $mode = $options->{mode} // 'simulate';
    croak "Unsupported dead-letter-check mode: $mode"
      if !$VALID_MODE{$mode};

    my $evidence = eval { return $self->_run_mode( $mode, $options ) };
    if ( !$evidence ) {
        return evidence_finalize(
            {
                check  => 'dead_letter_check',
                status => $STATUS_FAIL,
                mode   => $mode,
                error  => _trim($EVAL_ERROR),
                residual_gaps =>
                  [ $RESIDUAL_BETA, $RESIDUAL_LIVE, $RESIDUAL_SIM ],
            }
        );
    }

    return evidence_finalize($evidence);
}

sub format_evidence {
    my ( $self, $evidence, $format ) = @_;

    $evidence = evidence_finalize( $evidence // {} );
    $format ||= 'json';
    return $self->human_text($evidence) if $format eq 'human';

    return encode_json($evidence) . "\n";
}

sub human_text {
    my ( $self, $evidence ) = @_;

    my @lines = (
        'dead-letter-check status=' . ( $evidence->{status} // 'fail' ),
        'mode=' . ( $evidence->{mode} // 'unknown' ),
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

sub exit_status {
    my ( $self, $evidence ) = @_;

    return 0 if ( $evidence->{status} // q{} ) eq $STATUS_PASS;

    return $EXIT_FAILURE;
}

sub _run_mode {
    my ( $self, $mode, $options ) = @_;

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

sub _simulate {
    my ( $self, $options ) = @_;

    my $stack = $self->_simulate_stack($options);
    my $first = $stack->{dispatcher}->dispatch_pending(1);
    my $letter_count = scalar @{ $stack->{dead_letters}->created };
    my $outbox_status =
      $stack->{message}->get_column('status') // q{};
    my $failure_type =
      ( $stack->{dead_letters}->created->[0]{failure_type} // q{} );

    my @steps = (
        {
            name   => 'force_permanent_failure',
            status => ( ( $first->{dead_lettered} // 0 ) == 1
                  && ( $first->{failed} // 0 ) == 0 ) ? $STATUS_PASS : $STATUS_FAIL,
            summary => $first,
        },
        {
            name   => 'assert_dead_letter_and_cancelled',
            status => ( $letter_count == 1
                  && $outbox_status eq 'cancelled'
                  && $failure_type eq 'permanent' ) ? $STATUS_PASS : $STATUS_FAIL,
            dead_letters   => $letter_count,
            outbox_status  => $outbox_status,
            failure_type   => $failure_type,
        },
    );

    my $second = $stack->{dispatcher}->dispatch_pending(1);
    push @steps,
      {
        name     => 'redispatch_selected_zero',
        status   => ( ( $second->{selected} // -1 ) == 0 )
        ? $STATUS_PASS
        : $STATUS_FAIL,
        summary  => $second,
      };

    my $purged =
      $stack->{dead_letters}->purge_older_than('2020-01-01T00:00:00Z');
    my $remaining = scalar @{ $stack->{dead_letters}->created };
    push @steps,
      {
        name      => 'fresh_row_survives_retention_cutoff',
        status    => ( $purged == 0 && $remaining == 1 )
        ? $STATUS_PASS
        : $STATUS_FAIL,
        purged    => $purged,
        remaining => $remaining,
        note      =>
'Cutoff in the past must not delete a fresh dead-letter (retention hold).',
      };

    my $status = ( grep { $_->{status} ne $STATUS_PASS } @steps )
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

sub _simulate_stack {
    my ( $self, $options ) = @_;

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
    my $outbox = GPForum::Service::Operations::DeadLetterCheck::ProbeOutbox->new(
        rows => [$message],
    );
    my $letters =
      GPForum::Service::Operations::DeadLetterCheck::ProbeLetters->new;
    my $schema = GPForum::Service::Operations::DeadLetterCheck::ProbeSchema->new(
        outbox_resultset      => $outbox,
        dead_letter_resultset => $letters,
    );
    my $transport =
      GPForum::Service::Operations::DeadLetterCheck::ProbeTransport->new(
        fail_ids   => { $PROBE_OUTBOX_ID => 1 },
        fail_types => { $PROBE_OUTBOX_ID => 'permanent' },
      );
    my $dispatcher = GPForum::Service::Outbox::Dispatcher->new(
        schema       => $schema,
        transport    => $transport,
        clock        => GPForum::Service::Operations::DeadLetterCheck::ProbeClock
          ->new,
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

sub _trim {
    my ($error) = @_;

    $error = "$error";
    $error =~ s/\s+\z//msx;

    return $error;
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value;
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeFailure;

use strict;
use warnings;

use overload q{""} => sub { return $_[0]->{message} }, fallback => 1;

sub new {
    my ( $class, $message, $failure_type ) = @_;

    return bless {
        message      => $message // 'probe failure',
        failure_type => $failure_type,
    }, $class;
}

sub throw {
    my ( $class, $message, $failure_type ) = @_;

    die $class->new( $message, $failure_type );
}

sub failure_type {
    my ($self) = @_;

    return $self->{failure_type};
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeTransport;

use strict;
use warnings;

use Mojo::Base -base;

has fail_ids   => sub { return {}; };
has fail_types => sub { return {}; };

sub dispatch {
    my ( $self, $message ) = @_;

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

use strict;
use warnings;

use Mojo::Base -base;

has data    => sub { return {}; };
has updates => sub { return []; };

sub update {
    my ( $self, $changes ) = @_;

    push @{ $self->updates }, $changes;
    for my $key ( keys %{$changes} ) {
        $self->data->{$key} = $changes->{$key};
    }

    return $self;
}

sub get_column {
    my ( $self, $column ) = @_;

    return $self->data->{$column};
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeSearch;

use strict;
use warnings;

use Mojo::Base -base;

has rows => sub { return []; };

sub all {
    my ($self) = @_;

    return @{ $self->rows };
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeOutbox;

use strict;
use warnings;

use Mojo::Base -base;

has rows => sub { return []; };

sub search {
    my ( $self, $query, $attrs ) = @_;

    my @matched = grep { _row_matches( $_, $query ) } @{ $self->rows };
    my $limit   = $attrs->{rows};
    if ( defined $limit && $limit < @matched ) {
        @matched = @matched[ 0 .. $limit - 1 ];
    }

    return GPForum::Service::Operations::DeadLetterCheck::ProbeSearch->new(
        rows => \@matched, );
}

sub _row_matches {
    my ( $row, $query ) = @_;

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

use strict;
use warnings;

use Mojo::Base -base;

has created => sub { return []; };
has rows    => sub { return {}; };

sub create {
    my ( $self, $row ) = @_;

    my $key = join q{:}, $row->{source_table} // q{}, $row->{source_id} // q{};
    $self->rows->{$key} = $row;
    push @{ $self->created }, $row;

    return $row;
}

sub find {
    my ( $self, $query ) = @_;

    my $key = join q{:}, $query->{source_table} // q{},
      $query->{source_id} // q{};

    return $self->rows->{$key};
}

sub purge_older_than {
    my ( $self, $cutoff ) = @_;

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
                ( join q{:}, $_->{source_table} // q{}, $_->{source_id} // q{} )
                  => $_
            } @kept
        }
    );

    return $purged;
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeSchema;

use strict;
use warnings;

use Mojo::Base -base;

has outbox_resultset      => undef;
has dead_letter_resultset => undef;

sub resultset {
    my ( $self, $name ) = @_;

    return $self->outbox_resultset      if $name eq 'OutboxMessage';
    return $self->dead_letter_resultset if $name eq 'DeadLetter';

    return;
}

sub txn_do {
    my ( $self, $code ) = @_;

    return $code->();
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeClock;

use strict;
use warnings;

use Mojo::Base -base;

sub now_iso8601 {
    return '2026-09-21T12:00:00Z';
}

sub epoch_plus_iso8601 {
    my ( $self, $seconds ) = @_;

    return '2026-09-21T12:01:00Z' if $seconds;
    return '2026-09-21T12:00:00Z';
}

1;

package GPForum::Service::Operations::DeadLetterCheck::ProbeId;

use strict;
use warnings;

use Mojo::Base -base;

has counter => 0;

sub uuid {
    my ($self) = @_;

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
Emits EvidenceMeta JSON. Does not claim private-beta readiness; C<--live>
against staging PostgreSQL remains a residual.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
