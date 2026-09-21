package GPForum::Service::Operations::MailCheck;

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

const my $STATUS_PASS          => 'pass';
const my $STATUS_FAIL          => 'fail';
const my $DEFAULT_TO           => 'mail-check@localhost';
const my $PROBE_TOKEN          => 'mail-check-probe-token';
const my $SMTP_TIMEOUT_SECONDS => 5;
const my @SENDMAIL_CANDIDATES =>
  qw(/usr/sbin/sendmail /usr/lib/sendmail /usr/bin/sendmail);
const my %VALID_TRANSPORT => map { $_ => 1 } qw(test smtp sendmail);
const my %VALID_MODE      => map { $_ => 1 } qw(dry_run send);

has config            => undef;
has mailer            => undef;
has smtp_connector    => undef;
has sendmail_resolver => undef;

sub run {
    my ( $self, $options ) = @_;

    $options ||= {};
    return $self->_finalize_evidence( $self->_run_with_options($options),
        $options );
}

sub format_evidence {
    my ( $self, $evidence, $format ) = @_;

    $evidence = $self->_finalize_evidence( $evidence // {}, {} );
    $format ||= 'json';
    return $self->human_text($evidence) if $format eq 'human';

    return encode_json($evidence) . "\n";
}

sub human_text {
    my ( $self, $evidence ) = @_;

    return join( "\n", @{ $self->_human_lines($evidence) } ) . "\n";
}

sub exit_status {
    my ( undef, $evidence ) = @_;

    return 0 if ( $evidence->{status} // q{} ) eq $STATUS_PASS;

    return 1;
}

sub _run_with_options {
    my ( $self, $options ) = @_;

    my $mode = $options->{mode} // 'dry_run';
    return $self->_fail( 'mode must be dry_run or send', $options )
      if !exists $VALID_MODE{$mode};

    my $config = eval { return $self->_config };
    return $self->_fail( _trim($EVAL_ERROR), $options ) if $EVAL_ERROR;

    return $self->_run_configured( $config, $options, $mode );
}

sub _run_configured {
    my ( $self, $config, $options, $mode ) = @_;

    my $summary = $self->_config_summary($config);
    my $error   = $self->_config_error($summary);
    return $self->_config_fail( $mode, $summary, $error ) if $error;

    my $probe = $self->_probe_for( $mode, $config, $options );
    return $self->_evidence( $mode, $summary, $probe );
}

sub _probe_for {
    my ( $self, $mode, $config, $options ) = @_;

    return $self->_send_probe( $config, $options ) if $mode eq 'send';

    return $self->_dry_run_probe( $config, $options );
}

sub _evidence {
    my ( undef, $mode, $summary, $probe ) = @_;

    my %evidence = (
        status => $probe->{status},
        check  => 'mail_delivery',
        mode   => $mode,
        config => $summary,
        probe  => $probe,
    );
    $evidence{error} = $probe->{error} if _has_text( $probe->{error} );

    return \%evidence;
}

sub _finalize_evidence {
    my ( $self, $evidence, $options ) = @_;

    $evidence ||= {};
    $options  ||= {};

    my $config = $self->config;
    my @secrets;
    push @secrets, $PROBE_TOKEN;
    if ($config) {
        push @secrets, $config->smtp_password
          if eval { return _has_text( $config->smtp_password ) };
    }

    $evidence->{check} = 'mail_delivery';
    return evidence_finalize(
        $evidence,
        secrets    => \@secrets,
        extra_gaps => _residual_gaps_for($evidence),
    );
}

sub _residual_gaps_for {
    my ($evidence) = @_;

    my $mode      = $evidence->{mode} // 'dry_run';
    my $transport = $evidence->{config}{mail_transport} // q{};
    my @gaps      = (
'This mail-check does not claim private-beta readiness by itself.',
'Archive JSON beside staging-host-verify / stress-load evidence for the candidate commit.',
    );

    if ( $mode eq 'dry_run' ) {
        push @gaps,
'Controlled --send to an operator mailbox on staging SMTP/sendmail is still required before beta self-service mail claims.';
    }
    if ( $transport eq 'test' ) {
        push @gaps,
'Transport is Email::Sender::Transport::Test; staging SMTP or sendmail evidence remains open.';
    }
    if ( $mode eq 'send' && ( $evidence->{status} // q{} ) eq $STATUS_PASS ) {
        push @gaps,
'A single verification probe send is not a full identity-mail lifecycle drill (reset/change email with seeded roles).';
    }

    return \@gaps;
}

sub _config_fail {
    my ( undef, $mode, $summary, $error ) = @_;

    return {
        status => $STATUS_FAIL,
        check  => 'mail_delivery',
        mode   => $mode,
        config => $summary,
        error  => $error,
        probe  => { status => $STATUS_FAIL, action => 'config' },
    };
}

sub _human_lines {
    my ( $self, $evidence ) = @_;

    my @lines = (
        @{ $self->_human_header($evidence) },
        @{ $self->_human_smtp_lines($evidence) },
        @{ $self->_human_probe_lines($evidence) },
    );

    return \@lines;
}

sub _human_header {
    my ( undef, $evidence ) = @_;

    my $config = $evidence->{config} // {};
    return [
        'gpforum-mail-check status=' . ( $evidence->{status} // $STATUS_FAIL ),
        'mode=' .                      ( $evidence->{mode}   // 'dry_run' ),
        'mail_transport=' .            ( $config->{mail_transport}  // q{} ),
        'mail_from=' .                 ( $config->{mail_from}       // q{} ),
        'public_base_url=' .           ( $config->{public_base_url} // q{} ),
    ];
}

sub _human_smtp_lines {
    my ( undef, $evidence ) = @_;

    my $config = $evidence->{config} // {};
    return [] if ( $config->{mail_transport} // q{} ) ne 'smtp';

    my $smtp = $config->{smtp} // {};
    return [ 'smtp_host='
          . ( $smtp->{host} // q{} )
          . ' smtp_port='
          . ( $smtp->{port} // q{} )
          . ' smtp_ssl='
          . ( $smtp->{ssl} // 0 )
          . ' smtp_username_configured='
          . ( $smtp->{username_configured} ? 1 : 0 ) ];
}

sub _human_probe_lines {
    my ( undef, $evidence ) = @_;

    my $probe = $evidence->{probe} // {};
    my @lines = (
        'probe_action=' . ( $probe->{action} // 'none' ),
        'probe_status=' . ( $probe->{status} // $STATUS_FAIL ),
    );
    push @lines, 'probe_detail=' . $probe->{detail}
      if _has_text( $probe->{detail} );
    push @lines, 'error=' . $evidence->{error}
      if _has_text( $evidence->{error} );

    return \@lines;
}

sub _dry_run_probe {
    my ( $self, $config, $options ) = @_;

    my $transport = $config->mail_transport;
    return $self->_test_transport_probe( $config, $options )
      if $transport eq 'test';
    return $self->_smtp_connectivity_probe($config) if $transport eq 'smtp';
    return $self->_sendmail_presence_probe          if $transport eq 'sendmail';

    return {
        status => $STATUS_FAIL,
        action => 'dry_run',
        error  => "unsupported mail_transport: $transport",
    };
}

sub _send_probe {
    my ( $self, $config, $options ) = @_;

    my $to = $options->{to};
    return {
        status => $STATUS_FAIL,
        action => 'send',
        error  => '--to is required with --send',
      }
      if !_has_text($to);

    return $self->_deliver_probe( $config, $to, 'send' );
}

sub _test_transport_probe {
    my ( $self, $config, $options ) = @_;

    my $to     = $options->{to} // $DEFAULT_TO;
    my $result = $self->_deliver_probe( $config, $to, 'test_transport' );
    return $result if $result->{status} ne $STATUS_PASS;

    $result->{delivery_count} =
      $self->_delivery_count( $self->_mailer($config) );
    $result->{detail}         = 'Email::Sender::Transport::Test accepted probe';
    $result->{secrets_leaked} = 0;

    return $result;
}

sub _deliver_probe {
    my ( $self, $config, $to, $action ) = @_;

    my $mailer = $self->_mailer($config);
    my $result = eval {
        return $mailer->send_email_verification(
            {
                to    => $to,
                token => $PROBE_TOKEN,
            }
        );
    };
    if ($EVAL_ERROR) {
        return {
            status => $STATUS_FAIL,
            action => $action,
            to     => $to,
            error  => _scrub_text( _trim($EVAL_ERROR),
                [ $PROBE_TOKEN, $config->smtp_password // q{} ] ),
        };
    }

    return {
        status         => $STATUS_PASS,
        action         => $action,
        to             => $to,
        delivered      => $result->{ok} ? 1 : 0,
        detail         => 'identity verification probe mailed',
        secrets_leaked => 0,
    };
}

sub _delivery_count {
    my ( undef, $mailer ) = @_;

    my $transport = $mailer->transport;
    return $transport->delivery_count    if $transport->can('delivery_count');
    return scalar $transport->deliveries if $transport->can('deliveries');

    return 0;
}

sub _smtp_connectivity_probe {
    my ( $self, $config ) = @_;

    my $host = $config->smtp_host;
    my $port = int $config->smtp_port;
    my $ok   = eval {
        return $self->_smtp_connector->( $host, $port, $SMTP_TIMEOUT_SECONDS );
    };
    return $self->_smtp_fail( $host, $port, _trim($EVAL_ERROR) ) if $EVAL_ERROR;
    return $self->_smtp_fail( $host, $port,
        "SMTP TCP connect failed to $host:$port" )
      if !$ok;

    return {
        status         => $STATUS_PASS,
        action         => 'smtp_connect',
        host           => $host,
        port           => $port,
        detail         => "TCP connect to $host:$port succeeded",
        secrets_leaked => 0,
    };
}

sub _smtp_fail {
    my ( $self, $host, $port, $error ) = @_;

    my @secrets = ($PROBE_TOKEN);
    my $config  = $self->config;
    push @secrets, $config->smtp_password
      if $config && eval { return _has_text( $config->smtp_password ) };

    return {
        status => $STATUS_FAIL,
        action => 'smtp_connect',
        host   => $host,
        port   => $port,
        error  => _scrub_text( $error, \@secrets ),
    };
}

sub _sendmail_presence_probe {
    my ($self) = @_;

    my $path = eval { return $self->_sendmail_resolver->() };
    return {
        status => $STATUS_FAIL,
        action => 'sendmail_path',
        error  => _trim($EVAL_ERROR),
      }
      if $EVAL_ERROR;
    return {
        status => $STATUS_FAIL,
        action => 'sendmail_path',
        error  => 'sendmail binary not found on PATH or common locations',
      }
      if !_has_text($path);

    return {
        status         => $STATUS_PASS,
        action         => 'sendmail_path',
        path           => $path,
        detail         => "sendmail available at $path",
        secrets_leaked => 0,
    };
}

sub _config_summary {
    my ( undef, $config ) = @_;

    return {
        environment     => $config->environment,
        mail_transport  => $config->mail_transport,
        mail_from       => $config->mail_from,
        public_base_url => $config->public_base_url,
        smtp            => {
            host                => $config->smtp_host,
            port                => int $config->smtp_port,
            ssl                 => int $config->smtp_ssl,
            username_configured => _has_text( $config->smtp_username ) ? 1 : 0,
        },
    };
}

sub _config_error {
    my ( undef, $summary ) = @_;

    my $transport = $summary->{mail_transport} // q{};
    return 'mail_transport must be test, smtp, or sendmail'
      if !exists $VALID_TRANSPORT{$transport};
    return 'mail_from must be non-empty' if !_has_text( $summary->{mail_from} );
    return 'public_base_url must be non-empty'
      if !_has_text( $summary->{public_base_url} );
    return 'smtp_host must be non-empty for smtp transport'
      if $transport eq 'smtp' && !_has_text( $summary->{smtp}{host} );

    return;
}

sub _fail {
    my ( undef, $error, $options ) = @_;

    return {
        status => $STATUS_FAIL,
        check  => 'mail_delivery',
        mode   => $options->{mode} // 'dry_run',
        error  => $error,
        probe  => { status => $STATUS_FAIL, action => 'config' },
    };
}

sub _config {
    my ($self) = @_;

    return $self->config if $self->config;

    return GPForum::Config->from_environment;
}

sub _mailer {
    my ( $self, $config ) = @_;

    return $self->mailer if $self->mailer;

    my $mailer = GPForum::Service::Identity::Mailer->from_config($config);
    $self->mailer($mailer);

    return $mailer;
}

sub _smtp_connector {
    my ($self) = @_;

    return $self->smtp_connector if $self->smtp_connector;

    return \&_default_smtp_connect;
}

sub _sendmail_resolver {
    my ($self) = @_;

    return $self->sendmail_resolver if $self->sendmail_resolver;

    return \&_default_sendmail_path;
}

sub _default_smtp_connect {
    my ( $host, $port, $timeout ) = @_;

    require IO::Socket::IP;
    my $socket = IO::Socket::IP->new(
        PeerHost => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => $timeout,
    );
    croak "SMTP TCP connect failed to $host:$port: $OS_ERROR" if !$socket;
    close $socket or croak "failed to close SMTP probe socket: $OS_ERROR";

    return 1;
}

sub _default_sendmail_path {
    for my $candidate (@SENDMAIL_CANDIDATES) {
        return $candidate if -x $candidate;
    }

    return _sendmail_from_path();
}

sub _sendmail_from_path {
    for my $dir ( split /:/msx, ( $ENV{PATH} // q{} ) ) {
        next if !_has_text($dir);
        my $candidate = "$dir/sendmail";
        return $candidate if -x $candidate;
    }

    return;
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value;
}

sub _trim {
    my ($error) = @_;

    $error = "$error";
    $error =~ s/\s+\z//msx;

    return $error;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::MailCheck - Operator identity mail delivery check.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $check = GPForum::Service::Operations::MailCheck->new;
    my $report = $check->run( { mode => 'dry_run' } );

=head1 DESCRIPTION

Loads mail settings from L<GPForum::Config>, reports transport and from
address without leaking SMTP passwords, and probes delivery readiness for
C<test>, C<smtp>, and C<sendmail> transports. Evidence is finalized with
C<secrets_redacted>, explicit C<residual_gaps>, and scrubbed error text.
Does not claim private-beta readiness.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
