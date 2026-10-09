# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::MailCheck;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use GPForum::X::Unavailable;
use JSON::MaybeXS qw(encode_json);
use List::Util    qw(first);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(encode);

use GPForum::Config;
use GPForum::Service::Identity::Mailer;
use GPForum::Service::Operations::EvidenceMeta
  qw(evidence_finalize evidence_scrub_text);
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Host;

our $VERSION = '0.001';

# The command a finding offers to prove delivery. With --human: a finding is
# read in sentences, and mail-check without it answers in JSON, its evidence
# form, so the command copied from a finding printed a JSON document. The
# address is a word to replace, not an example one: you@example.com, copied
# as offered, sent the probe to a domain that takes no mail, and doctor
# refuses that domain everywhere else.
const my $SEND_COMMAND => 'gpforum mail-check --send --to ADDRESS --human';

const my $STATUS_PASS          => 'pass';
const my $STATUS_FAIL          => 'fail';
const my $DEFAULT_TO           => 'mail-check@localhost';
const my $PROBE_TOKEN          => 'mail-check-probe-token';
const my $SMTP_TIMEOUT_SECONDS => 5;
const my @SENDMAIL_CANDIDATES =>
  qw(/usr/sbin/sendmail /usr/lib/sendmail /usr/bin/sendmail);
const my %VALID_TRANSPORT => map { $_ => 1 } qw(sendmail smtp log test);
const my %VALID_MODE      => map { $_ => 1 } qw(dry_run send);

has config            => undef;  # optional: from the environment
has mailer            => undef;  # optional: built from the configuration
has smtp_connector    => undef;  # optional: a test's double; else a TCP connect
has sendmail_resolver => undef;  # optional: a test's double; else a PATH search
has host => sub { return GPForum::Service::Operations::Host->new; };

sub run ( $self, $options ) {
    $options ||= {};
    return $self->_finalize_evidence( $self->_run_with_options($options),
        $options );
}

sub format_evidence ( $self, $evidence, $format ) {
    $evidence = $self->_finalize_evidence( $evidence // {}, {} );
    $format ||= 'json';
    return encode( 'UTF-8', $self->human_text($evidence) )
      if $format eq 'human';

    return encode_json($evidence) . "\n";
}

sub human_text ( $self, $evidence ) {
    return $self->findings($evidence)->human_text;
}

# What a run proved, as an operator reads it. A dry run proves less than it
# seems to: a sendmail program found is not a message delivered, and a port
# that answers is not a server that takes the message. Each line says what
# it proved, and how to prove the rest.
sub findings ( $self, $evidence, $findings = undef ) {
    $findings //= GPForum::Service::Operations::Findings->new(
        catalog => $self->host->catalog );
    my $probe  = $evidence->{probe} // {};
    my $passed = ( $evidence->{status} // q{} ) eq $STATUS_PASS;
    my ( $message, $notes, $fixes ) =
        $passed
      ? $self->_proved( $evidence, $probe )
      : $self->_not_proved( $evidence, $probe );

    return $findings->add(
        name    => 'mail',
        status  => $passed ? 'ok' : 'fail',
        message => $message,
        notes   => $notes,
        fixes   => $fixes,
    );
}

sub _proved ( $self, $evidence, $probe ) {
    my $config = $evidence->{config}  // {};
    my $from   = $config->{mail_from} // q{};
    my $action = $probe->{action}     // q{};
    my $send   = [ 'mailcheck.prove_delivery', { command => $SEND_COMMAND } ];

    return ( [ 'mailcheck.sent', { to => $probe->{to}, from => $from } ],
        [ ['mailcheck.check_inbox'] ], [] )
      if $action eq 'send';
    return ( ['mailcheck.log'],  [], [] ) if $action eq 'log_transport';
    return ( ['mailcheck.test'], [], [] )
      if $action eq 'test_transport';
    return (
        [
            'mailcheck.smtp',
            { from => $from, host => $probe->{host}, port => $probe->{port} }
        ],
        [ ['mailcheck.proves_port'], $send ],
        []
    ) if $action eq 'smtp_connect';

    my @notes = ( ['mailcheck.proves_program'], $send );
    if ( $self->host->is_deployed ) {
        push @notes, ['mailcheck.vps'];
    }

    return (
        [ 'mailcheck.sendmail', { from => $from, path => $probe->{path} } ],
        \@notes, [] );
}

sub _not_proved ( $self, $evidence, $probe ) {
    my $action = $probe->{action} // q{};
    my $where  = { where => $self->host->where };
    my $error  = $evidence->{error} // $probe->{error} // q{};

    return (
        [ 'mailcheck.sendmail_missing', {} ],
        [],
        [ [ 'mailcheck.fix_mta', {} ], [ 'mailcheck.fix_use_smtp', $where ], ]
    ) if $action eq 'sendmail_path';
    return (
        [
            'mailcheck.smtp_unreachable',
            { host => $probe->{host}, port => $probe->{port} }
        ],
        [ [ 'mailcheck.said', { error => $error } ] ],
        [
            [ 'mailcheck.fix_smtp_settings', $where ],
            [ 'mailcheck.fix_smtp_blocked',  {} ],
        ]
    ) if $action eq 'smtp_connect';
    return ( [ 'mailcheck.to_missing', {} ],
        [], [ [ 'mailcheck.fix_to', { command => $SEND_COMMAND } ] ] )
      if $action eq 'send' && !defined $probe->{to};
    return ( [ 'mailcheck.not_sent', { to => $probe->{to} } ],
        [ [ 'mailcheck.said', { error => $error } ] ], [] )
      if $action eq 'send';

    return ( [ 'mailcheck.settings', { error => $error } ], [], [] );
}

sub exit_status ( $, $evidence ) {
    return 0 if ( $evidence->{status} // q{} ) eq $STATUS_PASS;

    return 1;
}

sub _run_with_options ( $self, $options ) {
    my $mode = $options->{mode} // 'dry_run';
    return $self->_fail( 'mode must be dry_run or send', $options )
      if !exists $VALID_MODE{$mode};

    my $config;
    try {
        $config = $self->config || GPForum::Config->from_environment;
    }
    catch ($error) {
        return $self->_fail( _trim($error), $options );
    };

    my $summary = _config_summary($config);
    if ( my $error = _config_error($summary) ) {
        return {
            status => $STATUS_FAIL,
            check  => 'mail_delivery',
            mode   => $mode,
            config => $summary,
            error  => $error,
            probe  => { status => $STATUS_FAIL, action => 'config' },
        };
    }

    my $probe =
        $mode eq 'send'
      ? $self->_send_probe( $config, $options )
      : $self->_dry_run_probe( $config, $options );
    my %evidence = (
        status => $probe->{status},
        check  => 'mail_delivery',
        mode   => $mode,
        config => $summary,
        probe  => $probe,
    );
    if ( _has_text( $probe->{error} ) ) {
        $evidence{error} = $probe->{error};
    }

    return \%evidence;
}

sub _finalize_evidence ( $self, $evidence, $options ) {
    $evidence ||= {};
    $options  ||= {};

    $evidence->{check} = 'mail_delivery';
    return evidence_finalize(
        $evidence,
        secrets    => $self->_secrets,
        extra_gaps => _residual_gaps_for($evidence),
    );
}

sub _residual_gaps_for ($evidence) {
    my $mode      = $evidence->{mode}                   // 'dry_run';
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
    if ( $transport eq 'log' ) {
        push @gaps,
'Transport is log, which writes mail to the log; staging SMTP or sendmail evidence remains open.';
    }
    if ( $mode eq 'send' && ( $evidence->{status} // q{} ) eq $STATUS_PASS ) {
        push @gaps,
'A single verification probe send is not a full identity-mail lifecycle drill; run script/mail-lifecycle-check --simulate, then still archive staging SMTP --send.';
    }

    return \@gaps;
}

sub _dry_run_probe ( $self, $config, $options ) {
    my $transport = $config->mail_transport;
    return $self->_test_transport_probe( $config, $options )
      if $transport eq 'test';
    return $self->_smtp_connectivity_probe($config) if $transport eq 'smtp';
    return $self->_sendmail_presence_probe          if $transport eq 'sendmail';
    return _log_transport_probe()                   if $transport eq 'log';

    return {
        status => $STATUS_FAIL,
        action => 'dry_run',
        error  => "unsupported mail_transport: $transport",
    };
}

# The log transport delivers nowhere, so a dry run has nothing to reach: it
# says so, and writes nothing to the log.
sub _log_transport_probe {
    return {
        status => $STATUS_PASS,
        action => 'log_transport',
        detail => 'log transport writes each message to the log;'
          . ' nothing is delivered',
        secrets_leaked => 0,
    };
}

sub _send_probe ( $self, $config, $options ) {
    my $to = $options->{to};
    return {
        status => $STATUS_FAIL,
        action => 'send',
        error  => '--to is required with --send',
      }
      if !_has_text($to);

    return $self->_deliver_probe( $config, $to, 'send' );
}

sub _test_transport_probe ( $self, $config, $options ) {
    my $to     = $options->{to} // $DEFAULT_TO;
    my $result = $self->_deliver_probe( $config, $to, 'test_transport' );
    return $result if $result->{status} ne $STATUS_PASS;

    $result->{delivery_count} =
      $self->_mailer($config)->transport->delivery_count;
    $result->{detail}         = 'Email::Sender::Transport::Test accepted probe';
    $result->{secrets_leaked} = 0;

    return $result;
}

sub _deliver_probe ( $self, $config, $to, $action ) {
    my $mailer = $self->_mailer($config);
    my $result;
    try {
        $result = $mailer->send_email_verification(
            {
                to    => $to,
                token => $PROBE_TOKEN,
            }
        );
    }
    catch ($error) {
        return {
            status => $STATUS_FAIL,
            action => $action,
            to     => $to,
            error  => evidence_scrub_text(
                _trim($error), [ $PROBE_TOKEN, $config->smtp_password // q{} ]
            ),
        };
    };

    return {
        status         => $STATUS_PASS,
        action         => $action,
        to             => $to,
        delivered      => $result->{ok} ? 1 : 0,
        detail         => 'identity verification probe mailed',
        secrets_leaked => 0,
    };
}

sub _smtp_connectivity_probe ( $self, $config ) {
    my $host = $config->smtp_host;
    my $port = int $config->smtp_port;
    my $ok;
    try {
        $ok = ( $self->smtp_connector || \&_default_smtp_connect )
          ->( $host, $port, $SMTP_TIMEOUT_SECONDS );
    }
    catch ($error) {
        return $self->_smtp_fail( $host, $port, _trim($error) );
    };
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

sub _smtp_fail ( $self, $host, $port, $error ) {
    return {
        status => $STATUS_FAIL,
        action => 'smtp_connect',
        host   => $host,
        port   => $port,
        error  => evidence_scrub_text( $error, $self->_secrets ),
    };
}

sub _sendmail_presence_probe ($self) {
    my $path;
    try {
        $path = ( $self->sendmail_resolver || \&_default_sendmail_path )->();
    }
    catch ($error) {
        return {
            status => $STATUS_FAIL,
            action => 'sendmail_path',
            error  => _trim($error),
        };
    };
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

sub _config_summary ($config) {
    return {
        environment     => $config->environment,
        mail_transport  => $config->mail_transport,
        mail_from       => $config->mail_from,
        public_base_url => $config->public_base_url,
        smtp            => {
            host                => $config->smtp_host,
            port                => int $config->smtp_port,
            ssl                 => int $config->smtp_ssl,
            tls                 => $config->smtp_tls,
            username_configured => _has_text( $config->smtp_username ) ? 1 : 0,
        },
    };
}

sub _config_error ($summary) {
    my $transport = $summary->{mail_transport} // q{};
    return 'mail_transport must be sendmail, smtp, log, or test'
      if !exists $VALID_TRANSPORT{$transport};
    return 'mail_from must be non-empty' if !_has_text( $summary->{mail_from} );
    return 'public_base_url must be non-empty'
      if !_has_text( $summary->{public_base_url} );
    return 'smtp_host must be non-empty for smtp transport'
      if $transport eq 'smtp' && !_has_text( $summary->{smtp}{host} );

    return undef;
}

sub _fail ( $, $error, $options ) {
    return {
        status => $STATUS_FAIL,
        check  => 'mail_delivery',
        mode   => $options->{mode} // 'dry_run',
        error  => $error,
        probe  => { status => $STATUS_FAIL, action => 'config' },
    };
}

sub _mailer ( $self, $config ) {
    return $self->mailer if $self->mailer;

    my $mailer = GPForum::Service::Identity::Mailer->from_config($config);
    $self->mailer($mailer);

    return $mailer;
}

sub _default_smtp_connect ( $host, $port, $timeout ) {
    require IO::Socket::IP;
    my $socket = IO::Socket::IP->new(
        PeerHost => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => $timeout,
    );
    if ( !$socket ) {
        GPForum::X::Unavailable->throw(
            message => "SMTP TCP connect failed to $host:$port: $OS_ERROR" );
    }
    close $socket or croak "failed to close SMTP probe socket: $OS_ERROR";

    return 1;
}

# The usual places first, then PATH.
sub _default_sendmail_path {
    my @on_path = map { "$_/sendmail" }
      grep { _has_text($_) } split /:/msx, $ENV{PATH} // q{};

    return first { -x } @SENDMAIL_CANDIDATES, @on_path;
}

sub _has_text ($value) {
    return defined $value && length $value;
}

# What evidence must never show: the probe token, and the configured SMTP
# password when there is one and the configuration can say (a partial double
# or a config that died cannot).
sub _secrets ($self) {
    my $password;
    if ( my $config = $self->config ) {
        try {
            $password = $config->smtp_password;
        }
        catch ($error) {
            $password = undef;
        };
    }

    return [ $PROBE_TOKEN, _has_text($password) ? $password : () ];
}

sub _trim ($error) {
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
C<test>, C<smtp>, C<sendmail> and C<log> transports. Evidence is finalized with
C<secrets_redacted>, explicit C<residual_gaps>, and scrubbed error text.
Does not claim private-beta readiness.

In C<dry_run> mode (the default) nothing reaches a real mailbox: the
C<test> transport takes the verification probe in memory and reports how
many messages it holds; for C<smtp> a TCP connection to the configured
host and port is opened, with a five-second timeout, and closed without
speaking SMTP; for C<sendmail> an executable C<sendmail> is looked for in
C</usr/sbin>, C</usr/lib>, C</usr/bin> and then on C<PATH>; C<log>, which
delivers nowhere, passes and writes nothing. In C<send>
mode an identity verification message carrying a probe token is mailed
through the configured transport to the C<to> address, which is required.

Before any probe the settings themselves are checked: C<mail_transport>
must be C<sendmail>, C<smtp>, C<log> or C<test>, C<mail_from> and
C<public_base_url> must be set, and C<smtp> needs C<smtp_host>.

The attributes are C<config> (a L<GPForum::Config>; read from the
environment when unset), C<mailer> (built from the configuration when
unset), and C<smtp_connector> and C<sendmail_resolver>, code references
that replace the TCP connection and the C<sendmail> lookup.

=head1 SUBROUTINES/METHODS

=head2 run

Takes a hash reference (or undef) with C<mode> (C<dry_run>, the default,
or C<send>) and C<to> (the recipient; required with C<send>, and
C<mail-check@localhost> for a C<dry_run> on the C<test> transport when
omitted). Returns the finalized evidence hash reference: C<check>
(C<mail_delivery>), C<status> (C<pass> or C<fail>), C<mode>, C<config>
(the transport, from address, public base URL, environment, and SMTP host,
port, SSL flag and whether a username is set; never the password),
C<probe> (what was tried and how it went), C<error> when it failed, and the
L<GPForum::Service::Operations::EvidenceMeta> fields C<secrets_redacted>,
C<private_beta_claimed> (0) and C<residual_gaps>. The residual gaps say
what this run does not prove: a dry run still needs a controlled send, the
C<test> transport proves nothing about staging mail, and one probe is not
the identity-mail lifecycle.

=head2 format_evidence

Takes an evidence hash reference (or undef) and a format (C<human>, or
C<json> by default). Finalizes the evidence again, then returns
C<human_text> of it, or its JSON encoding followed by a newline.

=head2 human_text

Takes an evidence hash reference. Returns its L</findings> as the lines an
operator reads, ending with what there is to fix.

=head2 findings

Takes an evidence hash reference and, optionally, a
L<GPForum::Service::Operations::Findings> to add to, and adds one finding,
C<mail>, in the operator's language: what was proved -- a message sent, a
port that answers, a program that exists, mail written to the log -- and
what was not, with the command that proves delivery. Once deployed, a
C<sendmail> transport adds that a VPS often cannot send on port 25 and needs
SPF and a PTR record. A failure names the settings, the file and the
package that fix it. Returns the findings.

=head2 host

The L<GPForum::Service::Operations::Host> whose environment and settings
file the findings name.

=head2 exit_status

Takes an evidence hash reference. Returns 0 when its status is C<pass>,
else 1.

=head1 DIAGNOSTICS

C<run> reports failures in the evidence rather than dying: an unknown
mode (C<mode must be dry_run or send>), a configuration that cannot be
loaded or is invalid, a failed connection, a missing C<sendmail>, or a
send the transport refused. The SMTP password and the probe token are
replaced by C<[redacted]> wherever they appear, and so is any field whose
name mentions a password, secret, token, authorization or credential.

=head1 CONFIGURATION AND ENVIRONMENT

Without a C<config>, the settings come from
L<GPForum::Config/from_environment>: C<GPFORUM_MAIL_TRANSPORT>,
C<GPFORUM_MAIL_FROM>, C<GPFORUM_PUBLIC_BASE_URL>, C<GPFORUM_SMTP_HOST>,
C<GPFORUM_SMTP_PORT>, C<GPFORUM_SMTP_TLS> (or its old name
C<GPFORUM_SMTP_SSL>), C<GPFORUM_SMTP_USERNAME> and C<GPFORUM_SMTP_PASSWORD>.
The evidence's C<config.smtp> gives C<tls> (C<starttls>, C<implicit> or
C<off>) and, for the archived runs that read it, C<ssl> (1 unless C<off>).
The C<sendmail> lookup reads C<PATH>.

=head1 DEPENDENCIES

L<Const::Fast>, L<JSON::MaybeXS>, L<Mojo::Base>, L<IO::Socket::IP> (for
the SMTP connection), L<GPForum::Config>,
L<GPForum::Service::Identity::Mailer>,
L<GPForum::Service::Operations::EvidenceMeta>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The C<smtp> dry run proves only that the port accepts a TCP connection,
not that the server would accept the message or the credentials.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
