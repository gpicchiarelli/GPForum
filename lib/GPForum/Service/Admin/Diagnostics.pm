# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::Diagnostics;

use strict;
use warnings;

use Const::Fast;
use English      qw(-no_match_vars);
use Scalar::Util qw(blessed);
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Id;
use GPForum::Infrastructure::Row;
use GPForum::Service::Admin::AuditReview;
use GPForum::Service::Admin::ConsoleReader;
use GPForum::Service::Admin::Settings;
use GPForum::Service::Clock;
use GPForum::Service::Identity::Mailer;
use GPForum::Service::Operations::AntivirusCheck;
use GPForum::Service::Operations::EvidenceMeta qw(evidence_scrub_structure);

our $VERSION = '0.001';

const my $SCHEMA_VERSION   => 1;
const my $MAIL_ACTION      => 'admin.mail_test_sent';
const my $ANTIVIRUS_ACTION => 'admin.antivirus_checked';
const my $MAX_ERROR_LENGTH => 500;
const my $RECIPIENT        => '[recipient]';

# The send runs inside a web request, and Hypnotoad restarts a worker that
# sends no heartbeat for heartbeat_interval + heartbeat_timeout -- ten
# seconds as shipped. Email::Sender waits 120 seconds on each SMTP step by
# default; five lets one stalled step fail, and be reported, in time.
const my $SMTP_TIMEOUT_SECONDS => 5;

# Both checks run inside their command's transaction, which sits idle while
# the SMTP server or clamd answers. PostgreSQL ends a transaction idle for
# database_idle_in_transaction_timeout_ms -- ten seconds as shipped -- and
# the audit row goes with it: a stalled clamd takes three seconds on each of
# the check's four calls, twelve in all, and the console then had nothing to
# show for the check meant to find it. This transaction alone is allowed a
# minute, longer than either check can wait; SET LOCAL ends with it.
const my $SLOW_ANSWER_IDLE_MS => 60_000;
const my $ALLOW_SLOW_ANSWER =>
  q{SELECT set_config('idle_in_transaction_session_timeout', ?, true)};

has accounts => sub ($self) {
    return GPForum::Service::Admin::ConsoleReader->new(
        schema => $self->schema );
};

# The scanner the application scans uploads with, or undef when scanning is
# off (GPForum::Infrastructure::Antivirus->from_config).
has antivirus    => undef;
has audit_review => sub ($self) {
    return GPForum::Service::Admin::AuditReview->new( schema => $self->schema );
};
has clock      => sub { return GPForum::Service::Clock->new; };
has config     => undef;
has id_service => sub { return GPForum::Infrastructure::Id->new; };
has mailer     => sub ($self) {
    return GPForum::Service::Identity::Mailer->new(
        config       => $self->config,
        smtp_timeout => $SMTP_TIMEOUT_SECONDS,
    );
};
has recorder => sub ($self) {
    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema   => undef;
has settings => sub ($self) {
    return GPForum::Service::Admin::Settings->new( config => $self->config );
};

# What the settings page shows beside its two buttons: where a test message
# would go, how mail and scanning are configured, and the last audited
# result of each.
sub overview ( $self, $user_id ) {
    return {
        antivirus => {
            engine     => $self->config->antivirus,
            in_request => $self->_scans_in_request,
            latest     => $self->_latest($ANTIVIRUS_ACTION),
        },
        mail => {
            latest    => $self->_latest($MAIL_ACTION),
            recipient => $self->accounts->email_of($user_id),
            transport => $self->config->mail_transport,
        },
    };
}

# 6.5: the console's bin/gpforum-mail-check. One message, to the signed-in
# administrator's own address and never to one the request names -- the
# console must not become a relay -- and the outcome audited either way.
sub send_test_mail ( $self, $input ) {
    my $actor_user_id = $input->{actor_user_id};
    my $to            = $self->accounts->email_of($actor_user_id);
    my $outcome =
      ( defined $to && length $to )
      ? $self->_deliver($to)
      : { error => 'this account has no email address', outcome => 'failed' };
    my $result = { %{$outcome}, transport => $self->config->mail_transport };

    # The recipient is the actor, so the audit row names them as its target
    # instead of copying their address into the log; the result, which the
    # command log keeps as the command's answer, leaves it out for the same
    # reason.
    $self->_audit(
        {
            action        => $MAIL_ACTION,
            actor_user_id => $actor_user_id,
            metadata      => {
                (
                    defined $result->{error}
                    ? ( error => $result->{error} )
                    : ()
                ),
                outcome   => $result->{outcome},
                transport => $result->{transport},
                via       => 'web',
            },
            target_id   => $actor_user_id,
            target_type => 'user',
        }
    );

    return $result;
}

# 6.5: the console's bin/gpforum-antivirus-check, audited with its report.
sub check_antivirus ( $self, $input ) {
    $self->_allow_slow_answer;
    my $report = evidence_scrub_structure( $self->_antivirus_report,
        $self->settings->secret_values );
    my $correlation_id = $self->id_service->uuid;
    $self->_audit(
        {
            action         => $ANTIVIRUS_ACTION,
            actor_user_id  => $input->{actor_user_id},
            correlation_id => $correlation_id,
            metadata       => { %{$report}, via => 'web' },
            target_id      => $correlation_id,
            target_type    => 'antivirus',
        }
    );

    return $report;
}

# A transport failure is the outcome being tested, not an error of this
# command: it is caught here, so the audit row recording it commits. It
# touches no database, so catching it leaves the command's transaction as
# it was. A server's refusal often quotes the recipient ("<a@b>: Recipient
# address rejected"); the address is replaced, as it is kept out of the
# audit row everywhere else.
sub _deliver ( $self, $to ) {
    $self->_allow_slow_answer;
    my $sent =
      eval { $self->mailer->send_test_message( { to => $to } ); return 1; };
    return { outcome => 'sent' } if $sent;

    return {
        error   => $self->_scrubbed( $EVAL_ERROR, $to ),
        outcome => 'failed',
    };
}

sub _allow_slow_answer ($self) {
    my $configured = $self->config->database_idle_in_transaction_timeout_ms;
    my $storage    = $self->schema ? $self->schema->storage : undef;
    return if !$storage    || !$storage->can('dbh_do');
    return if !$configured || $configured >= $SLOW_ANSWER_IDLE_MS;

    $storage->dbh_do(
        sub ( $, $dbh ) {
            return $dbh->do( $ALLOW_SLOW_ANSWER, undef, $SLOW_ANSWER_IDLE_MS );
        }
    );

    return;
}

# A command scanner (clamscan) loads its signatures for every file; the
# three scans would outlast the request. Only a resident clamd answers in
# time, and only within the request budget Clamd->within_request sets.
sub _antivirus_report ($self) {
    my $scanner = $self->antivirus;
    my $engine  = $self->config->antivirus;
    if ( !$self->_scans_in_request ) {
        return {
            engine   => $engine,
            problems => [],
            reason   => 'command_scanner',
            status   => 'not_run',
        };
    }

    my $check = GPForum::Service::Operations::AntivirusCheck->new(
        clock  => $self->clock,
        config => $self->config,
        ( $scanner ? ( scanner => $scanner->within_request ) : () ),
    );
    my $report = eval { return $check->run };
    if ( !$report ) {
        return {
            engine   => $engine,
            problems => [ $self->_scrubbed($EVAL_ERROR) ],
            status   => 'fail',
        };
    }

    # The shell's wording speaks of "this shell"; the console has none.
    if ( $report->{status} eq 'disabled' ) {
        $report->{detail} =
            'scanning is off (GPFORUM_ANTIVIRUS=none): uploads are checked'
          . ' for format only';
    }

    return $report;
}

sub _scans_in_request ($self) {
    my $scanner = $self->antivirus;

    return ( !$scanner || $scanner->answers_immediately ) ? 1 : 0;
}

# The newest audited result of an action, which is what the page shows: it
# survives the redirect and is the same for every administrator.
sub _latest ( $self, $action ) {
    my $page =
      $self->audit_review->page( { action => $action }, { limit => 1 } );
    my ($row) = @{ $page->{rows} || [] };
    my $none;
    return $none if !$row;

    return {
        actor_id => GPForum::Infrastructure::Row->column( $row, 'actor_id' ),
        at       => GPForum::Infrastructure::Row->column( $row, 'created_at' ),
        result   => _metadata($row),
    };
}

# get_column hands back a JSON column as its text; the inflated value is the
# hash it was written from.
sub _metadata ($row) {
    my $metadata =
        ref $row eq 'HASH'               ? $row->{metadata}
      : $row->can('get_inflated_column') ? $row->get_inflated_column('metadata')
      :                                    undef;

    return ref $metadata eq 'HASH' ? $metadata : {};
}

# An Email::Sender::Failure stringifies with its stack trace, whose frames
# can carry the arguments of the SMTP login; its message is what went wrong.
# Not every failure is one: without Authen::SASL, Email::Sender confesses
# that SMTP AUTH is impossible, a plain string whose tab-indented frames name
# the server's paths and the arguments of every call down to this one, the
# recipient included. Only the line before the frames is kept.
sub _scrubbed ( $self, $error, $recipient = undef ) {
    my $text =
        !defined $error                              ? 'unknown failure'
      : ( blessed $error && $error->can('message') ) ? $error->message
      :                                                "$error";
    $text =~ s/\n\t.*\z//msx;
    $text =~ s/\s+ at \s+ \S+ \s+ line \s+ \d+ [.]? \s* \z//msx;
    $text =~ s/\s+\z//msx;
    if ( defined $recipient && length $recipient ) {
        $text =~ s/\Q$recipient\E/$RECIPIENT/gmsxi;
    }

    # Redacted before it is shortened, so the cut cannot leave half a secret.
    $text = $self->settings->redact($text);
    if ( length $text > $MAX_ERROR_LENGTH ) {
        $text = substr( $text, 0, $MAX_ERROR_LENGTH ) . q{...};
    }

    return $text;
}

sub _audit ( $self, $input ) {
    return $self->recorder->record_audit(
        action         => $input->{action},
        actor_id       => $input->{actor_user_id},
        correlation_id => $input->{correlation_id} // $self->id_service->uuid,
        created_at     => $self->clock->now_iso8601,
        metadata       => $input->{metadata},
        previous_hash  => undef,
        record_hash    => q{},
        schema_version => $SCHEMA_VERSION,
        target_id      => $input->{target_id},
        target_type    => $input->{target_type},
    );
}

1;

__END__

=head1 NAME

GPForum::Service::Admin::Diagnostics - Send a test message and check the antivirus from the console.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $diagnostics = GPForum::Service::Admin::Diagnostics->new(
        antivirus => $scanner,
        config    => $config,
        schema    => $schema,
    );
    my $overview = $diagnostics->overview($admin_id);
    my $mail     = $diagnostics->send_test_mail( { actor_user_id => $admin_id } );
    my $report   = $diagnostics->check_antivirus( { actor_user_id => $admin_id } );

=head1 DESCRIPTION

The console side of two shell checks (quality program 6.5).
C<send_test_mail> is C<bin/gpforum-mail-check --send>, restricted to the
signed-in administrator's own address: it never takes a recipient from the
request, so the console cannot be used to send mail anywhere else.
C<check_antivirus> runs L<GPForum::Service::Operations::AntivirusCheck>, what
C<bin/gpforum-antivirus-check> runs, against the application's scanner within
the request budget. Each is audited (C<admin.mail_test_sent>,
C<admin.antivirus_checked>) with its outcome, in the caller's transaction, and
a transport error or report is shown with every configured secret redacted
(L<GPForum::Service::Admin::Settings/redact>).

=head1 SUBROUTINES/METHODS

=head2 overview

The administrator's own address, the mail transport, the scanning engine,
whether it can be checked within a request, and the last audited result of
each check.

=head2 send_test_mail

Sends one test message to the actor's address and audits the outcome:
C<outcome> C<sent> or C<failed> (with C<error>) and C<transport>. The address
is in neither the result nor the audit row: where the transport's error
quotes it, it reads C<[recipient]>.

=head2 check_antivirus

Runs the antivirus check and audits its report: C<status> C<ok>,
C<degraded>, C<fail>, C<disabled>, or C<not_run> when the scanner is a
command, which cannot answer within a request.

=head1 DIAGNOSTICS

A transport failure or a failed scan is a result, not an exception. The audit
write dies when the database does; the workflow's transaction then rolls back.

=head1 CONFIGURATION AND ENVIRONMENT

The C<GPFORUM_MAIL_*>, C<GPFORUM_SMTP_*> and C<GPFORUM_ANTIVIRUS*> settings in
L<GPForum::Config>.

=head1 DEPENDENCIES

L<GPForum::Service::Identity::Mailer>,
L<GPForum::Service::Operations::AntivirusCheck>,
L<GPForum::Service::Admin::Settings>,
L<GPForum::Infrastructure::EventRecorder>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The message is sent, and the scanner checked, inside the request, with the
command's transaction open meanwhile: an SMTP server slower than five
seconds a step fails the test, and that transaction may sit idle for up to a
minute (C<idle_in_transaction_session_timeout>, raised for it alone). A
stalled clamd or SMTP server can hold the request past Hypnotoad's
heartbeat; the worker then finishes it and is restarted. A server that
scans with a command (C<GPFORUM_ANTIVIRUS=command>) is checked from the
shell only.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
