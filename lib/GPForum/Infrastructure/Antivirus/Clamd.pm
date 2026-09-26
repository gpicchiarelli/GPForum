# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::Antivirus::Clamd;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Errno   qw(EAGAIN EINTR EWOULDBLOCK);
use IO::Select;
use IO::Socket::UNIX;
use List::Util qw(min);
use Mojo::Base -base, -signatures;
use Socket      qw(SOCK_STREAM);
use Time::HiRes qw(time);
use Time::Piece ();

our $VERSION = '0.001';

const my $CHUNK_BYTES      => 65_536;
const my $READ_BYTES       => 4_096;
const my $DEFAULT_TIMEOUT  => 30;
const my $TERMINATOR       => "\0";
const my $STALE_DAYS       => 3;
const my $VERSION_PARTS    => 3;
const my $REQUEST_BUDGET   => 3;
const my $DAY_SECONDS      => 86_400;
const my $PUBLISHED_FORMAT => '%a %b %d %H:%M:%S %Y';

# The clamd the operating system's package runs, reached on its local socket.
# Content goes over INSTREAM, so clamd never needs to read GPForum's storage.
has socket_path     => undef;
has timeout_seconds => $DEFAULT_TIMEOUT;

# A verdict for the bytes: status clean, infected (with the signature) or
# error (with why). An error is never a verdict about the file -- the caller
# must not treat it as clean. The scan and the VERSION that names its engine
# share one deadline, so a scan never takes longer than timeout_seconds.
sub scan ( $self, $content ) {
    my $deadline = time + $self->timeout_seconds;
    my $reply    = eval { return $self->_instream( $content, $deadline ); };
    if ( !defined $reply ) {
        return _error( _trimmed($EVAL_ERROR) );
    }

    my $verdict = _verdict($reply);
    $verdict->{engine} = $self->_engine($deadline);

    return $verdict;
}

# A copy of this scanner bounded for use inside a web request. Hypnotoad
# restarts a worker that sends no heartbeat for heartbeat_interval +
# heartbeat_timeout -- ten seconds as shipped -- and a request that waits on
# clamd sends none. Three seconds leaves room; what does not fit stays
# pending for the attachment worker, which has the full timeout.
sub within_request ($self) {
    return ( ref $self )
      ->new( %{$self},
        timeout_seconds => min( $self->timeout_seconds, $REQUEST_BUDGET ), );
}

# A resident daemon with its signatures loaded: fast enough to scan inside the
# upload request.
sub answers_immediately {
    return 1;
}

# Whether a batch of scans is worth starting.
sub available ($self) {
    return eval { $self->ping } ? 1 : 0;
}

sub ping ($self) {
    return $self->_command('PING') eq 'PONG' ? 1 : 0;
}

# "ClamAV 1.4.1/27400/Tue Sep 24 08:23:45 2026" as its parts: the engine, the
# signature database version and the date of the newest signatures.
sub version ( $self, $deadline = undef ) {
    my $reply = $self->_command( 'VERSION', $deadline );
    my ( $engine, $database, $date ) = split m{/}msx, $reply, $VERSION_PARTS;

    return {
        engine    => $engine,
        database  => $database,
        published => $date,
        reply     => $reply,
    };
}

# For readiness. freshclam normally refreshes signatures several times a day;
# three days old means it has stopped. Either problem degrades uploads -- they
# wait, unserved, until clamd can scan them -- not the forum, so neither is a
# failure that should take the node out of service.
sub health ( $self, $now_epoch ) {
    my %check   = ( mode => 'clamd', socket => $self->socket_path );
    my $version = eval { return $self->version; };
    if ( !$version ) {
        return {
            %check,
            status => 'degraded',
            error  => _trimmed($EVAL_ERROR)
        };
    }

    my $published = eval {

        # clamd writes the date in the host's local time (ctime), so it is
        # read as local time; read as UTC it would be off by the offset.
        return Time::Piece->localtime->strptime( $version->{published} // q{},
            $PUBLISHED_FORMAT )->epoch;
    };
    my %report = (
        %check,
        engine    => $version->{engine},
        database  => $version->{database},
        published => $version->{published},
    );
    if ( !defined $published ) {
        return {
            %report,
            status => 'degraded',
            error  => 'clamd reported no signature date'
        };
    }
    if ( $now_epoch - $published > $STALE_DAYS * $DAY_SECONDS ) {
        return {
            %report,
            status => 'degraded',
            error  => 'signatures older than three days; is freshclam running?'
        };
    }

    return { %report, status => 'ok' };
}

sub _engine ( $self, $deadline ) {
    my $version = eval { return $self->version($deadline); };
    return 'clamd' if !$version;

    return join q{/}, grep { defined } $version->{engine}, $version->{database};
}

# Every operation has one deadline, timeout_seconds from its start unless the
# caller shares its own, that every wait on the socket counts down to.
sub _command ( $self, $name, $deadline = undef ) {
    $deadline //= time + $self->timeout_seconds;
    my $socket = $self->_connect;
    _send( $socket, "z$name$TERMINATOR", $deadline );

    return _reply( $socket, $deadline );
}

sub _instream ( $self, $content, $deadline ) {
    if ( !utf8::downgrade( $content, 1 ) ) {
        croak 'antivirus content must be bytes, not characters';
    }

    my $socket = $self->_connect;

    # clamd answers and closes as soon as the stream passes its
    # StreamMaxLength. Writing after that raises SIGPIPE, which would kill the
    # worker; with it ignored the write fails and the reply explains why.
    local $SIG{PIPE} = 'IGNORE';
    my $sent = eval {
        _send( $socket, "zINSTREAM$TERMINATOR", $deadline );
        _send_chunks( $socket, $content, $deadline );
        _send( $socket, ( pack 'N', 0 ), $deadline );
        1;
    };
    my $send_error  = $EVAL_ERROR;
    my $reply       = eval { return _reply( $socket, $deadline ); };
    my $reply_error = $EVAL_ERROR;
    if ( defined $reply && length $reply ) {
        return $reply;
    }

    # Say what actually went wrong: the write when clamd stopped reading,
    # otherwise the read -- a timeout, or clamd hanging up without a word.
    croak $send_error  if !$sent;
    croak $reply_error if $reply_error;
    croak 'clamd closed the connection without a verdict';
}

sub _send_chunks ( $socket, $content, $deadline ) {
    my $length = length $content;
    my $offset = 0;
    while ( $offset < $length ) {
        my $chunk = substr $content, $offset, $CHUNK_BYTES;
        _send( $socket, pack( 'N', length $chunk ) . $chunk, $deadline );
        $offset += length $chunk;
    }

    return;
}

sub _connect ($self) {
    my $path = $self->socket_path;
    if ( !defined $path || !length $path ) {
        croak 'no clamd socket is known for this operating system;'
          . ' set GPFORUM_ANTIVIRUS_SOCKET';
    }

    my $socket = IO::Socket::UNIX->new(
        Type    => SOCK_STREAM,
        Peer    => $path,
        Timeout => $self->timeout_seconds,
    ) or croak "cannot connect to clamd at $path: $ERRNO";

    # Non-blocking, so no single write can outlast the deadline: a blocking
    # write of a whole chunk waits for clamd to read it, however long that
    # takes, on systems whose UNIX socket buffer is smaller than the chunk.
    $socket->blocking(0);

    return $socket;
}

sub _send ( $socket, $bytes, $deadline ) {
    my $select = IO::Select->new($socket);
    my $offset = 0;
    while ( $offset < length $bytes ) {
        if ( !$select->can_write( _remaining($deadline) ) ) {
            croak 'clamd stopped accepting data';
        }
        my $written = syswrite $socket, $bytes, length($bytes) - $offset,
          $offset;
        if ( !defined $written ) {
            next if _retryable();
            croak "writing to clamd failed: $ERRNO";
        }
        $offset += $written;
    }

    return;
}

sub _reply ( $socket, $deadline ) {
    my $select = IO::Select->new($socket);
    my $reply  = q{};
    while ( index( $reply, $TERMINATOR ) < 0 ) {
        if ( !$select->can_read( _remaining($deadline) ) ) {
            croak 'clamd did not answer in time';
        }
        my $buffer;
        my $read = sysread $socket, $buffer, $READ_BYTES;
        if ( !defined $read ) {
            next if _retryable();
            croak "reading from clamd failed: $ERRNO";
        }
        last if !$read;
        $reply .= $buffer;
    }

    my ($text) = split /\0/msx, $reply, 2;

    return defined $text ? $text : q{};
}

# Zero once the deadline has passed, so the wait returns at once and fails.
sub _remaining ($deadline) {
    my $seconds_left = $deadline - time;

    return $seconds_left > 0 ? $seconds_left : 0;
}

sub _retryable {
    my $errno = $ERRNO + 0;

    return $errno == EAGAIN || $errno == EWOULDBLOCK || $errno == EINTR;
}

sub _verdict ($reply) {
    if ( $reply =~ /\A stream: \s+ OK \z/msx ) {
        return { status => 'clean' };
    }
    if ( $reply =~ /\A stream: \s+ (.+?) \s+ FOUND \z/msx ) {
        return { status => 'infected', signature => $1 };
    }

    return _error("clamd: $reply");
}

sub _error ($message) {
    return { status => 'error', error => $message };
}

sub _trimmed ($message) {
    my $text = defined $message ? "$message" : 'unknown clamd failure';
    $text =~ s/\s+ at \s+ \S+ \s+ line \s+ \d+ [.]? \s* \z//msx;

    return $text;
}

1;

__END__

=head1 NAME

GPForum::Infrastructure::Antivirus::Clamd - Scan bytes with the system clamd.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $clamd = GPForum::Infrastructure::Antivirus::Clamd->new(
        socket_path => '/var/run/clamav/clamd.ctl' );
    my $verdict = $clamd->scan($bytes);   # { status => 'clean', engine => ... }

=head1 DESCRIPTION

A client for the ClamAV daemon the operating system's package installs. It
streams content over the local socket with the C<INSTREAM> command, so clamd
does not need access to GPForum's attachment storage, and reports a verdict
per scan. Every read and write is bounded by C<timeout_seconds>.

=head1 SUBROUTINES/METHODS

=head2 scan

Returns a hash with C<status> C<clean>, C<infected> (with C<signature>) or
C<error> (with C<error>), and the C<engine> that decided.

=head2 within_request

A copy whose every operation is bounded by three seconds (or less), for use
inside a web request.

=head2 answers_immediately

True: a resident clamd is fast enough to scan inside the upload request.

=head2 health

For readiness: C<ok> with the engine, signature database and its date;
C<degraded> when clamd cannot be reached or its signatures are more than
three days old.

=head2 available

True when clamd answers C<PING>; never dies.

=head2 ping

True when clamd answers C<PING>.

=head2 version

The engine, signature database version and signature date clamd reports.

=head1 DIAGNOSTICS

C<scan> never dies: a missing socket, a timeout, a closed connection or a
clamd C<ERROR> reply is an C<error> verdict. C<ping> and C<version> die when
clamd cannot be reached.

=head1 CONFIGURATION AND ENVIRONMENT

The socket comes from C<GPFORUM_ANTIVIRUS_SOCKET> or the operating system's
packaged default; see L<GPForum::Infrastructure::Antivirus>. clamd's
C<StreamMaxLength> must exceed the largest attachment GPForum accepts.

=head1 DEPENDENCIES

L<IO::Socket::UNIX>, L<IO::Select>, L<Const::Fast>, L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Local UNIX sockets only; a clamd listening on TCP is not supported.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
