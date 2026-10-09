# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::MailCheck;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::MailCheck;
use GPForum::X::Usage;

our $VERSION = '0.001';

# Each flag sets one option to one value.
const my %FLAG_OPTIONS => (
    '--help'    => [ help   => 1 ],
    '--json'    => [ format => 'json' ],
    '--human'   => [ format => 'human' ],
    '--dry-run' => [ mode   => 'dry_run' ],
    '--send'    => [ mode   => 'send' ],
);
const my %VALUE_OPTIONS => ( '--to' => 'to', );

# What --to takes: an address, with an @ between two words. The command
# doctor and a dry run offer says --to ADDRESS, and ADDRESS, typed as it
# was offered, went to sendmail as a local user's name and was reported as
# a message sent.
const my $ADDRESS => qr/\A [^@\s]+ [@] [^@\s]+ \z/msx;

# The usage's lines for the two formats, the default marked.
const my $JSON_DEFAULT => <<'FORMATS' =~ s/\n\z//rmsx;
  --human            the lines an operator reads
  --json             evidence as JSON (the default)
FORMATS
const my $HUMAN_DEFAULT => <<'FORMATS' =~ s/\n\z//rmsx;
  --human            the lines an operator reads (the default)
  --json             evidence as JSON
FORMATS

has check => undef;    # optional: a test's double; else the real check

# What it prints without --human or --json. The front door's verb answers in
# the lines an operator reads, as every other gpforum verb does (owner
# decision D12); bin/gpforum-mail-check and script/mail-check keep the JSON
# evidence the archived runs were made with.
has default_format => 'json';

# Misuse -- an option this command does not know, all its parser rejects --
# is the documented usage exit: the usage on stderr, status 2, without the
# " at bin/... line N." croak used to leave on it. A check that stops with an
# exception instead of evidence is a failure: 1 with its reason, redacted, on
# stderr and, as JSON, evidence saying fail (Command::Usage). It used to be
# rethrown with die, and an uncaught exception exits 255, or with whatever $!
# held: 2, misuse, after a failed file lookup.
sub run ( $self, @arguments ) {
    my $options;
    try {
        $options = $self->_options(@arguments);
    }
    catch ($error) {
        return GPForum::Command::Usage->error( undef,
            GPForum::Command::Usage->trimmed($error) );
    };

    return $self->_print_usage() if $options->{help};

    my $status;
    try {
        $status = $self->_run($options);
    }
    catch ($error) {
        return GPForum::Command::Usage->evidence_failure( $error,
            $options->{format},
            { check => 'mail_delivery', mode => $options->{mode} } );
    };

    return $status;
}

sub _run ( $self, $options ) {
    my $service  = $self->_service;
    my $evidence = $service->run($options);
    my $text     = $service->format_evidence( $evidence, $options->{format} );

    # The lines offer gpforum commands, the --send that proves delivery
    # among them, which read the file this run read, as doctor's do: typed
    # as offered after gpforum --env-file FILE mail-check, a bare one
    # checked the host's file instead. The JSON evidence stays as archived.
    if ( $options->{format} eq 'human' ) {
        $text = GPForum::Command::Support::ServiceEnvironment->as_read($text);
    }
    print $text or croak 'failed to write mail-check evidence';

    return $service->exit_status($evidence);
}

# Settings it cannot use stop the command before the check, as they stop
# every other: all of them on stderr in the operator's language, naming the
# environment file read, and 78 (Command::Usage). Inside the check they read
# as a finding, in English, that named the template and exited 1. TLS that
# this Perl cannot speak is one of them, as at the service's start: the dry
# run said the relay answered, and --send failed with Net::SMTP's own words.
sub _service ($self) {
    return $self->check if $self->check;

    return GPForum::Service::Operations::MailCheck->new(
        config => GPForum::Config->from_environment->assert_smtp_tls,
        host   => _host(),
    );
}

sub _options ( $self, @arguments ) {
    my %options = (
        format => $self->default_format,
        mode   => 'dry_run',
        help   => 0,
        to     => undef,
    );

    while (@arguments) {
        my $argument = shift @arguments;
        if ( exists $FLAG_OPTIONS{$argument} ) {
            my ( $name, $value ) = @{ $FLAG_OPTIONS{$argument} };
            $options{$name} = $value;
            next;
        }
        if ( !exists $VALUE_OPTIONS{$argument} ) {
            GPForum::X::Usage->throw(
                message => "Unknown option: $argument\n" . $self->usage_text );
        }

        my $value = shift @arguments;
        if ( !_has_text($value) ) {
            GPForum::X::Usage->throw(
                message => "$argument requires a value\n" . $self->usage_text );
        }
        $options{ $VALUE_OPTIONS{$argument} } = $value;
    }
    if ( defined $options{to} && $options{to} !~ $ADDRESS ) {
        GPForum::X::Usage->throw(
            message => GPForum::Command::Support::Words->new->text(
                'cli.admin.email_format', { value => $options{to} } )
              . "\n"
              . $self->usage_text
        );
    }

    return \%options;
}

sub _print_usage ($self) {
    return GPForum::Command::Usage->help( \*STDOUT, $self->usage_text );
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts. Called on the
# front door's instance, it says the lines are the default.
sub usage_text ($invocant) {
    my $human = ref $invocant && $invocant->default_format eq 'human';

    return _usage( $human ? $HUMAN_DEFAULT : $JSON_DEFAULT );
}

# The host the findings' fixes are written for, naming the environment file
# the front door read, where the settings to correct are.
sub _host {
    my $file = GPForum::Command::Support::ServiceEnvironment->loaded;

    return GPForum::Service::Operations::Host->new(
        defined $file ? ( environment_file => $file ) : () );
}

sub _usage ($formats) {
    return <<"USAGE";
Usage: bin/gpforum-mail-check [--human | --json] [--dry-run | --send --to ADDRESS]

Prove that GPForum's mail leaves this host. A dry run sends nothing and says
what it proved -- a sendmail program that exists, an SMTP port that answers,
mail written to the log -- and what it did not. Only --send proves delivery.

$formats
  --dry-run          check the settings and probe, sending nothing (the default)
  --send --to ADDRESS
                     send one verification message to ADDRESS, one you read
  --help             this text

Exit status: 0 it proved what it could; 1 it could not; 2 misuse;
78 settings it cannot use.
Settings: GPFORUM_MAIL_TRANSPORT, GPFORUM_MAIL_FROM, GPFORUM_PUBLIC_BASE_URL
and GPFORUM_SMTP_* (the password is never printed). docs/ops/mail-check.md
says more.
USAGE
}

sub _has_text ($value) {
    return defined $value && length $value;
}

1;

__END__

=head1 NAME

GPForum::Command::MailCheck - Operator CLI for identity mail verification.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::MailCheck->new->run(@ARGV);

=head1 DESCRIPTION

Thin CLI around L<GPForum::Service::Operations::MailCheck>.

=head1 SUBROUTINES/METHODS

=head2 check

The check to run; a test passes a double. Without one, a
L<GPForum::Service::Operations::MailCheck>.

=head2 run

Runs the command with its arguments; returns the exit status.

=head2 usage_text

The usage text, for the front door.

=head1 DIAGNOSTICS

Misuse exits 2 with the usage on standard error: an unknown option, or a
C<--to> that is not an address, such as the C<ADDRESS> the offered command
leaves to fill in. An error the check raises
instead of reporting exits 1 with its reason, redacted, on standard error
and, with C<--json> (the default), evidence on standard output with
C<status> C<fail> and the reason in C<error>. Settings it cannot use exit 78,
every problem on standard error in the operator's language, naming the
environment file read.

=head1 CONFIGURATION AND ENVIRONMENT

The mail configuration: C<GPFORUM_MAIL_TRANSPORT>, C<GPFORUM_MAIL_FROM>,
C<GPFORUM_PUBLIC_BASE_URL> and C<GPFORUM_SMTP_*>. The SMTP password is never
printed.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::MailCheck>, L<GPForum::Command::Usage>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A dry run proves the configuration and the transport's reachability, not
that a message arrives; only C<--send> delivers one.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
