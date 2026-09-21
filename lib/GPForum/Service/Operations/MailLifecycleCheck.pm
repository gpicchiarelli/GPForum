package GPForum::Service::Operations::MailLifecycleCheck;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base;

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

has config => undef;
has mailer => undef;
has transport_factory => undef;

sub run {
    my ( $self, $options ) = @_;

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

    return evidence_finalize(
        $evidence,
        secrets => [ $PROBE_RESET, $PROBE_CHANGE, $PROBE_VERIFY ],
    );
}

sub format_evidence {
    my ( $self, $evidence, $format ) = @_;

    $evidence = evidence_finalize(
        $evidence // {},
        secrets => [ $PROBE_RESET, $PROBE_CHANGE, $PROBE_VERIFY ],
    );
    $format ||= 'json';
    return $self->human_text($evidence) if $format eq 'human';

    return encode_json($evidence) . "\n";
}

sub human_text {
    my ( $self, $evidence ) = @_;

    my @lines = (
        'mail-lifecycle-check status=' . ( $evidence->{status} // 'fail' ),
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
        check  => 'mail_lifecycle_check',
        status => $STATUS_PASS,
        mode   => 'dry_run',
        plan   => {
            kinds =>
              [ 'password_reset', 'email_change', 'email_verification' ],
        },
        residual_gaps => [ $RESIDUAL_BETA, $RESIDUAL_SMTP, $RESIDUAL_SEED ],
    };
}

sub _simulate {
    my ( $self, $options ) = @_;

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

    my @deliveries = $transport->can('deliveries') ? $transport->deliveries : ();
    my $delivery_count = scalar @deliveries;
    push @steps,
      {
        name           => 'delivery_count',
        status         => ( $delivery_count == 3 ) ? $STATUS_PASS : $STATUS_FAIL,
        delivery_count => $delivery_count,
        expected       => 3,
      };

    my $link_status = $STATUS_PASS;
    my @link_checks;
    if ( $delivery_count == 3 ) {
        for my $index ( 0 .. $#kinds ) {
            my $body = eval { return $deliveries[$index]{email}->get_body }
              // q{};
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
        name    => 'identity_links',
        status  => $link_status,
        checks  => \@link_checks,
      };

    my $status = ( grep { $_->{status} ne $STATUS_PASS } @steps )
      ? $STATUS_FAIL
      : $STATUS_PASS;

    return {
        check         => 'mail_lifecycle_check',
        status        => $status,
        mode          => 'simulate',
        to            => $to,
        delivery_count => $delivery_count,
        steps         => \@steps,
        residual_gaps => [ $RESIDUAL_BETA, $RESIDUAL_SMTP, $RESIDUAL_SEED ],
    };
}

sub _mailer_and_transport {
    my ($self) = @_;

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

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
