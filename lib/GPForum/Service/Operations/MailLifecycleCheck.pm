# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::MailLifecycleCheck;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base, -signatures;

use GPForum::Config;
use GPForum::Service::Identity::Mailer;
use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);

our $VERSION = '0.001';

const my $EXIT_FAILURE => 1;
const my $STATUS_PASS  => 'pass';
const my $STATUS_FAIL  => 'fail';
const my $DEFAULT_TO   => 'mail-lifecycle@localhost';
const my $PROBE_RESET  => 'mail-lifecycle-reset-token';
const my $PROBE_CHANGE => 'mail-lifecycle-change-token';
const my $PROBE_VERIFY => 'mail-lifecycle-verify-token';
const my $RESIDUAL_BETA =>
  'This mail-lifecycle check does not claim private-beta readiness by itself.';
const my $RESIDUAL_SMTP =>
'Transport under test here is Email::Sender::Transport::Test; staging SMTP/sendmail --send evidence remains open via gpforum-mail-check.';
const my $RESIDUAL_SEED =>
'Seeded-role DB identity flows (register/reset/change with outbox dispatch) remain a separate staging walk.';
const my %VALID_MODE => map { $_ => 1 } qw(dry_run simulate);

has config            => undef;
has mailer            => undef;
has transport_factory => undef;

sub run ( $self, $options ) {
    $options ||= {};
    my $mode = $options->{mode} // 'simulate';
    croak "Unsupported mail-lifecycle-check mode: $mode"
      if !$VALID_MODE{$mode};

    my $evidence = eval { return $self->_run_mode( $mode, $options ) };
    if ( !$evidence ) {
        return evidence_finalize(
            {
                check         => 'mail_lifecycle_check',
                status        => $STATUS_FAIL,
                mode          => $mode,
                error         => _trim($EVAL_ERROR),
                residual_gaps =>
                  [ $RESIDUAL_BETA, $RESIDUAL_SMTP, $RESIDUAL_SEED ],
            },
            secrets => [ $PROBE_RESET, $PROBE_CHANGE, $PROBE_VERIFY ],
        );
    }

    return evidence_finalize( $evidence,
        secrets => [ $PROBE_RESET, $PROBE_CHANGE, $PROBE_VERIFY ], );
}

sub format_evidence ( $self, $evidence, $format ) {
    $evidence = evidence_finalize( $evidence // {},
        secrets => [ $PROBE_RESET, $PROBE_CHANGE, $PROBE_VERIFY ], );
    $format ||= 'json';
    return $self->human_text($evidence) if $format eq 'human';

    return encode_json($evidence) . "\n";
}

sub human_text ( $self, $evidence ) {
    my @lines = (
        'mail-lifecycle-check status=' . ( $evidence->{status} // 'fail' ),
        'mode=' .                        ( $evidence->{mode}   // 'unknown' ),
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
        check  => 'mail_lifecycle_check',
        status => $STATUS_PASS,
        mode   => 'dry_run',
        plan   => {
            kinds => [ 'password_reset', 'email_change', 'email_verification' ],
        },
        residual_gaps => [ $RESIDUAL_BETA, $RESIDUAL_SMTP, $RESIDUAL_SEED ],
    };
}

sub _simulate ( $self, $options ) {
    my $to = $options->{to} // $DEFAULT_TO;
    my ( $mailer, $transport ) = $self->_mailer_and_transport;
    my @kinds = (
        {
            name   => 'password_reset',
            method => 'send_password_reset',
            token  => $PROBE_RESET,
            path   => '/password/reset/',
        },
        {
            name   => 'email_change',
            method => 'send_email_change',
            token  => $PROBE_CHANGE,
            path   => '/email/confirm/',
        },
        {
            name   => 'email_verification',
            method => 'send_email_verification',
            token  => $PROBE_VERIFY,
            path   => '/email/verify/',
        },
    );

    my @steps;
    for my $kind (@kinds) {
        my $method = $kind->{method};
        my $ok     = eval {
            $mailer->$method( { to => $to, token => $kind->{token} } );
            return 1;
        };
        push @steps,
          {
            name   => $kind->{name},
            status => $ok ? $STATUS_PASS : $STATUS_FAIL,
            ( $ok ? () : ( error => _trim($EVAL_ERROR) ) ),
          };
    }

    my @deliveries =
      $transport->can('deliveries') ? $transport->deliveries : ();
    my $delivery_count = scalar @deliveries;
    push @steps,
      {
        name   => 'delivery_count',
        status => ( $delivery_count == 3 ) ? $STATUS_PASS : $STATUS_FAIL,
        delivery_count => $delivery_count,
        expected       => 3,
      };

    my $link_status = $STATUS_PASS;
    my @link_checks;
    if ( $delivery_count == 3 ) {
        for my $index ( 0 .. $#kinds ) {
            my $body =
              eval { return $deliveries[$index]{email}->get_body } // q{};
            my $needle = $kinds[$index]{path} . $kinds[$index]{token};
            my $found  = index( $body, $needle ) >= 0 ? 1 : 0;
            $link_status = $STATUS_FAIL if !$found;
            push @link_checks,
              {
                kind   => $kinds[$index]{name},
                status => $found ? $STATUS_PASS : $STATUS_FAIL,
              };
        }
    }
    else {
        $link_status = $STATUS_FAIL;
    }
    push @steps,
      {
        name   => 'identity_links',
        status => $link_status,
        checks => \@link_checks,
      };

    my $status =
      ( grep { $_->{status} ne $STATUS_PASS } @steps )
      ? $STATUS_FAIL
      : $STATUS_PASS;

    return {
        check          => 'mail_lifecycle_check',
        status         => $status,
        mode           => 'simulate',
        to             => $to,
        delivery_count => $delivery_count,
        steps          => \@steps,
        residual_gaps  => [ $RESIDUAL_BETA, $RESIDUAL_SMTP, $RESIDUAL_SEED ],
    };
}

sub _mailer_and_transport ($self) {
    if ( $self->mailer ) {
        return ( $self->mailer, $self->mailer->transport );
    }

    my $transport;
    if ( $self->transport_factory ) {
        $transport = $self->transport_factory->();
    }
    else {
        require Email::Sender::Transport::Test;
        $transport = Email::Sender::Transport::Test->new;
    }

    my $config = $self->config // GPForum::Config->new(
        mail_transport  => 'test',
        mail_from       => 'noreply@localhost',
        public_base_url => 'http://127.0.0.1:3000',
    );
    my $mailer = GPForum::Service::Identity::Mailer->new(
        config          => $config,
        from_address    => $config->mail_from,
        public_base_url => $config->public_base_url,
        transport       => $transport,
    );

    return ( $mailer, $transport );
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

__END__

=head1 NAME

GPForum::Service::Operations::MailLifecycleCheck - Identity mail kind drill.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $report = GPForum::Service::Operations::MailLifecycleCheck->new->run(
        { mode => 'simulate' }
    );

=head1 DESCRIPTION

Exercises C<password_reset>, C<email_change>, and C<email_verification>
through C<Identity::Mailer> under C<Email::Sender::Transport::Test>. Emits
EvidenceMeta JSON and scrubs probe tokens. Does not claim private-beta
readiness; staging SMTP C<--send> remains a residual.

The simulation sends each of the three messages to one address, then
checks that the transport holds exactly three deliveries and that each
body carries its link: C</password/reset/>, C</email/confirm/> and
C</email/verify/>, each followed by that kind's probe token. The run
passes only when every step does.

The attributes are C<mailer> (used as it is, with its own transport),
C<transport_factory> (a code reference returning the transport, when
there is no mailer; an L<Email::Sender::Transport::Test> otherwise) and
C<config> (the from address and public base URL of the mailer it builds;
when unset, C<noreply@localhost> and C<http://127.0.0.1:3000>).

=head1 SUBROUTINES/METHODS

=head2 run

Takes a hash reference (or undef) with C<mode> (C<simulate>, the default,
or C<dry_run>) and C<to> (default C<mail-lifecycle@localhost>). In
C<dry_run> mode nothing is sent, and the evidence is a passing plan that
lists the three kinds. In C<simulate> mode it returns the evidence with
C<check> (C<mail_lifecycle_check>), C<status>, C<mode>, C<to>,
C<delivery_count> and C<steps>: one per kind, with its error when the
mailer died, then C<delivery_count> (expected 3) and C<identity_links>
(one check per kind). Either way the evidence is finalized with
L<GPForum::Service::Operations::EvidenceMeta>, the probe tokens scrubbed,
and carries C<residual_gaps> for what a simulation cannot prove: staging
SMTP or C<sendmail> delivery, and the seeded database identity flows.

=head2 format_evidence

Takes an evidence hash reference (or undef) and a format (C<human>, or
C<json> by default). Finalizes the evidence again, then returns
C<human_text> of it, or its JSON encoding followed by a newline.

=head2 human_text

Takes an evidence hash reference. Returns its plain-text form: the status
and mode, a C<step name=status> line per step, the error if any, and a
C<residual:> line per residual gap.

=head2 exit_status

Takes an evidence hash reference. Returns 0 when its status is C<pass>,
else 1.

=head1 DIAGNOSTICS

C<run> croaks C<Unsupported mail-lifecycle-check mode: ...> for a mode
other than C<simulate> or C<dry_run>. Anything that dies during the run
itself is returned as failing evidence with the error, not rethrown.

=head1 CONFIGURATION AND ENVIRONMENT

None. It does not read L<GPForum::Config> from the environment: without a
C<config> it builds a C<test> configuration of its own.

=head1 DEPENDENCIES

L<Const::Fast>, L<JSON::MaybeXS>, L<Mojo::Base>,
L<Email::Sender::Transport::Test>, L<GPForum::Config>,
L<GPForum::Service::Identity::Mailer>,
L<GPForum::Service::Operations::EvidenceMeta>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The delivery and link checks read C<deliveries> from the transport, so a
transport without that method fails the run even when it sent the mail.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
