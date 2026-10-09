# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::MetricsTokens;

use Const::Fast;
use English               qw(-no_match_vars);
use Hash::Util::FieldHash qw(fieldhash);
use List::Util            qw(first);
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;
use Mojo::Util  qw(trim);
use Time::HiRes ();

use GPForum::Config;
use GPForum::Service::I18N::CliCatalog;

our $VERSION = '0.001';

# The tokens /metrics and the full /health reports accept, as the service's
# environment file names them now: gpforum secret rotate metrics, and its
# --finish, take effect without a restart (ADR 0124). The session secret is
# not among them: it signs cookies, and it changes with a restart only.
const my $CURRENT  => 'GPFORUM_METRICS_TOKEN';
const my $PREVIOUS => 'GPFORUM_METRICS_TOKENS';

# How a service file names the environment file its supervisor read, for a
# file that is not the host's own.
const my $DECLARED => 'GPFORUM_ENV_FILE';

# What stat tells of a file that changes when it is written: its device and
# inode (a rename puts another file in its place), mode, size, and the
# modification and change times, to the fraction of a second.
const my @SIGNATURE => ( 0, 1, 2, 7, 9, 10 );
const my $STAT_MODE => 2;

# A file another account may write could hand /metrics a token of its
# choosing: it is not read again, as the FreeBSD rc scripts refuse it.
const my $WRITABLE_BY_OTHERS => oct '022';

# The tokens each configuration the service started with follows: one, made
# before Hypnotoad forks, for the application's configuration. A field hash
# lets a configuration go when nothing else holds it.
fieldhash my %WATCHED;

# The settings the service started with.
__PACKAGE__->requires(qw(config));

has file => undef;    # optional: the environment file it follows, or none

# What reads a line of it: GPForum::Command::Support::ServiceEnvironment,
# whose parse_line the front door and the service read the file with.
has parser => undef;    # optional: with no file, nothing is read

has log     => undef;   # optional: a Mojo::Log
has catalog => sub { return GPForum::Service::I18N::CliCatalog->new; };

# Starts following the file a configuration's service was started with: the
# one its service file names in GPFORUM_ENV_FILE, else the one the parser
# read when the service loaded. Returns the tokens, which for_config gives
# from then on.
sub watch ( $class, $config, %options ) {
    my $environment = $options{environment} // \%ENV;
    my $parser      = $options{parser};
    my $file        = first { defined && length } $environment->{$DECLARED},
      ( defined $parser ? $parser->loaded : undef );

    my $self = $class->new(
        config => $config,
        file   => $file,
        parser => $parser,
        log    => $options{log},
    );
    $self->_start;
    $WATCHED{$config} = $self;

    return $self;
}

# What answers accepted_metrics_tokens for a configuration: the tokens
# watch made for it, or the configuration itself, whose list is fixed.
sub for_config ( $class, $config ) {
    return $WATCHED{$config} // $config;
}

# Whether the tokens follow the file, which watch decided once.
sub following ($self) {
    return $self->{following} ? 1 : 0;
}

# The tokens accepted now, the one in use first: the file's, read again
# when it has changed since it was last read.
sub accepted_metrics_tokens ($self) {
    if ( $self->{following} ) {
        $self->_refresh;
    }

    return [ @{ $self->{accepted} } ];
}

# The file is followed only when it holds the tokens the service started
# with: the supervisor read that same file moments before. A file that
# holds others is not the one the service's tokens came from -- another
# forum's on the same host, or one the shell overrode -- and the tokens stay
# as they started.
sub _start ($self) {
    $self->{accepted}  = $self->config->accepted_metrics_tokens;
    $self->{following} = 0;
    return if !defined $self->file || !defined $self->parser;

    my $read = $self->_read;
    if ( $read->{problem} ) {
        return $self->_said( 'warn', 'runtime.metrics_tokens_unfollowed',
            $read->{problem} );
    }
    if ( !_same( $read->{accepted}, $self->{accepted} ) ) {
        return $self->_said(
            'warn',
            'runtime.metrics_tokens_not_the_file',
            [ 'runtime.metrics_tokens_not_the_file', {} ]
        );
    }
    $self->{signature} = $read->{signature};
    $self->{following} = 1;

    return;
}

# One stat on each check; the file is read only when it changed. What it
# could not use is logged once, as its signature is kept, and the tokens
# accepted before stay: never none, so /metrics never opens to anyone.
sub _refresh ($self) {
    return if _signature( $self->file ) eq $self->{signature};

    my $read = $self->_read;
    return if !$read->{settled};

    $self->{signature} = $read->{signature};
    if ( $read->{problem} ) {
        return $self->_said( 'warn', 'runtime.metrics_tokens_kept',
            $read->{problem} );
    }

    my $accepted = $read->{accepted};
    if ( !length $accepted->[0] ) {
        return if !length $self->{accepted}[0];
        return $self->_said( 'warn', 'runtime.metrics_tokens_kept',
            [ 'runtime.metrics_tokens_none', { variable => $CURRENT } ] );
    }
    return if _same( $accepted, $self->{accepted} );

    $self->{accepted} = $accepted;
    return $self->_said( 'info', 'runtime.metrics_tokens_read',
        [ 'runtime.metrics_tokens_read', { count => scalar @{$accepted} } ] );
}

# The file's tokens as { signature, accepted, settled, problem }: settled
# when it did not change while it was read, so a write caught half way is
# read again at the next check; problem a [ key, parameters ] pair.
sub _read ($self) {
    my $file   = $self->file;
    my @before = Time::HiRes::stat($file);
    my %read   = ( signature => _signature_of(@before), settled => 1 );
    return { %read, problem => _unreadable() } if !@before;
    if ( $before[$STAT_MODE] & $WRITABLE_BY_OTHERS ) {
        return { %read, problem => [ 'runtime.metrics_tokens_writable', {} ] };
    }

    my $handle;
    return { %read, problem => _unreadable() }
      if !open $handle, '<:raw', $file;
    my @lines = <$handle>;
    close $handle or return { %read, problem => _unreadable() };
    $read{settled} = _signature($file) eq $read{signature} ? 1 : 0;

    my %value;
    my $number = 0;
    for my $line (@lines) {
        $number++;
        my $assignment = $self->parser->parse_line($line);
        next if !defined $assignment;
        if ( !ref $assignment ) {
            return { %read,
                problem =>
                  [ 'runtime.metrics_tokens_malformed', { line => $number } ] };
        }
        $value{ $assignment->[0] } = $assignment->[1];
    }

    # The rule the configuration reads them by: the one in use first, then
    # each earlier one not already listed.
    my $tokens = GPForum::Config->new(
        metrics_token           => $value{$CURRENT} // q{},
        previous_metrics_tokens => [
            grep { length } map { trim($_) } split /,/msx,
            $value{$PREVIOUS} // q{}
        ],
    );

    return { %read, accepted => $tokens->accepted_metrics_tokens };
}

# One line for the service's log, in the operator's language: the sentence,
# with the reason when there is one. Never a token.
sub _said ( $self, $level, $key, $reason ) {
    return if !defined $self->log;

    my ( $reason_key, $parameters ) = @{$reason};
    my %parameters = ( %{$parameters}, file => $self->file );
    my $because =
      $reason_key eq $key
      ? q{}
      : $self->catalog->text( $reason_key, \%parameters );
    $self->log->$level(
        $self->catalog->text( $key, { %parameters, reason => $because } ) );

    return;
}

sub _signature ($file) {
    return _signature_of( Time::HiRes::stat($file) );
}

sub _signature_of (@stat) {
    return 'absent' if !@stat;

    return join q{:}, map { $_ // q{} } @stat[@SIGNATURE];
}

# Why the file could not be read, as stat or open said.
sub _unreadable {
    return [ 'runtime.metrics_tokens_unreadable', { reason => "$OS_ERROR" } ];
}

sub _same ( $one, $other ) {
    return join( "\0", @{$one} ) eq join( "\0", @{$other} ) ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::MetricsTokens - The metrics tokens the
service accepts, as its environment file names them now.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # Once, before Hypnotoad forks (GPForum::Bootstrap::Operations):
    GPForum::Service::Operations::MetricsTokens->watch(
        $config,
        parser => 'GPForum::Command::Support::ServiceEnvironment',
        log    => $app->log,
    );

    # On each token check (GPForum::Web::OperationsAccess):
    my $tokens = GPForum::Service::Operations::MetricsTokens->for_config(
        $config)->accepted_metrics_tokens;

=head1 DESCRIPTION

C<gpforum secret rotate metrics> writes a new C<GPFORUM_METRICS_TOKEN> into
the environment file and keeps the one before in C<GPFORUM_METRICS_TOKENS>;
C<--finish> drops it. The running service follows the file, so both take
effect without a restart (ADR 0124).

The file is the one the service's supervisor read: the one its service file
names in C<GPFORUM_ENV_FILE>, else the one C<bin/gpforum> read when
Hypnotoad loaded it -- the host's, which every shipped unit names. It is
followed only when, at start, it holds exactly the tokens the service
started with; otherwise the tokens stay as they started, and the start logs
why.

Each check costs one C<stat>. The file is read again only when its device,
inode, mode, size or times changed, and only when it did not change while
it was read. A file that cannot be read, has a line that is not
C<NAME=value>, may be written by an account other than its owner, or names
no C<GPFORUM_METRICS_TOKEN> leaves the tokens as they were, logged once:
the tokens never become none, so C</metrics> never opens to anyone. The
comparison of a presented token stays L<GPForum::Web::OperationsAccess>'s,
in constant time.

=head1 SUBROUTINES/METHODS

=head2 watch

Class method. Takes the configuration the service started with and
C<parser> (an object or class with C<parse_line> and C<loaded>, as
L<GPForum::Command::Support::ServiceEnvironment> has), C<log> and, for a
test, C<environment>. Decides once whether the tokens follow the file, and
returns them.

=head2 for_config

Class method. What answers C<accepted_metrics_tokens> for a configuration:
the tokens C<watch> made for it, or the configuration itself, whose list
does not change.

=head2 following

True when the tokens follow the file.

=head2 accepted_metrics_tokens

The tokens accepted now, as an array reference, the one in use first, as
L<GPForum::Config/accepted_metrics_tokens> gives them.

=head2 config

The configuration the service started with.

=head2 file

The environment file followed, or undef.

=head2 parser

What reads a line of the file.

=head2 log

The L<Mojo::Log> the decisions are written to, or undef.

=head2 catalog

The L<GPForum::Service::I18N::CliCatalog> the log lines are written from.

=head1 DIAGNOSTICS

Logs, once each and without a token: why the file is not followed (at
start), why a changed file was not used (kept), and that the tokens were
read again (info).

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<GPFORUM_ENV_FILE>, and the C<GPFORUM_METRICS_TOKEN> and
C<GPFORUM_METRICS_TOKENS> lines of the file it follows. The process
environment decides the tokens the service starts with, as it decides every
other setting (ADR 0120).

=head1 DEPENDENCIES

L<GPForum::Base>, L<Hash::Util::FieldHash>, L<Time::HiRes>, L<GPForum::Config>,
L<GPForum::Service::I18N::CliCatalog>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Each Hypnotoad worker reads the file on its own, and logs its own line. A
service whose file is not the host's, started from a service file without
C<GPFORUM_ENV_FILE>, keeps the tokens it started with until it restarts.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
