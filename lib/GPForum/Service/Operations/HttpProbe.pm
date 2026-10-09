# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::HttpProbe;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp ();
use IPC::Open3 qw(open3);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);
use Mojo::IOLoop::TLS;
use Mojo::UserAgent;
use Symbol qw(gensym);

our $VERSION = '0.001';

# One GET, as an operator's check needs it: the status and the body, or why
# there was no answer, in a word a sentence can be chosen by -- refused,
# unresolved, timeout, handshake, tls -- and the words the client said.
#
# Mojo::UserAgent speaks https only with IO::Socket::SSL. The lock installs
# it, for mail over TLS; an install from before it did not, so there an
# https address, the public one, is asked through curl instead, which every
# host the deployment guide describes has (its health step uses it), and
# which checks the certificate as a browser would.

const my $DEFAULT_TIMEOUT => 5;
const my $EXIT_SHIFT      => 8;

# curl's exit statuses, by what they mean to an operator. A handshake that
# failed (35) is no certificate's fault: most often the port answers plain
# HTTP, or nothing there speaks TLS, which the proxy's set-up fixes, not a
# new certificate.
const my %CURL_KIND => (
    6  => 'unresolved',
    7  => 'refused',
    28 => 'timeout',
    35 => 'handshake',
    ( map { $_ => 'tls' } 51, 53, 54, 58, 59, 60, 64, 66, 77, 80, 82, 83 ),
);

# What Mojo::UserAgent's errors say, by the same words. OpenSSL's "wrong
# version number" is the handshake curl reports as 35: the port answered
# plain HTTP.
const my @MOJO_KIND => (
    [ refused    => qr/Connection [ ] refused|No [ ] such [ ] file/msxi ],
    [ unresolved => qr/not [ ] known|nodename|resolve|getaddrinfo/msxi ],
    [ unresolved => qr/No [ ] address [ ] associated/msxi ],
    [ timeout    => qr/timeout|timed [ ] out/msxi ],
    [ handshake  => qr/wrong [ ] version [ ] number/msxi ],
    [ handshake  => qr/unknown [ ] protocol/msxi ],
    [ handshake  => qr/alert [ ] protocol [ ] version/msxi ],
    [ tls        => qr/SSL|TLS|certificate/msx ],
);

# Why there was no answer, in the operator's words; any other reason is the
# client's own.
const my %REASON => (
    refused    => 'doctor.reason_refused',
    timeout    => 'doctor.reason_timeout',
    unresolved => 'doctor.reason_unresolved',
);

has timeout    => $DEFAULT_TIMEOUT;
has user_agent => sub ($self) {
    return Mojo::UserAgent->new->max_redirects(0)
      ->connect_timeout( $self->timeout )
      ->request_timeout( $self->timeout );
};

# curl, when there is one on the PATH; a test names its own.
has curl => sub { return _on_path('curl'); };

# Whether Mojo::UserAgent speaks https here: IO::Socket::SSL is installed.
# A test says no, to ask curl.
has can_tls => sub { return Mojo::IOLoop::TLS->can_tls; };

# Takes a URL and headers; returns { code, body, error, kind, client }: the
# HTTP status and body when the server answered, else the error and its
# kind. client is mojo or curl, whichever asked.
sub get ( $self, $url, $headers = {} ) {
    if ( $url =~ m{\A https://}msxi && !$self->can_tls ) {
        return $self->_curl( $url, $headers );
    }

    return $self->_mojo( $url, $headers );
}

# Why an answer from get did not come, as the end of a sentence, in the
# catalog's language: "connection refused", "no answer within 5 s", or the
# client's first line.
sub reason ( $self, $answer, $catalog ) {
    my $kind = $answer->{kind} // q{};
    return $catalog->text( $REASON{$kind}, { seconds => $self->timeout } )
      if exists $REASON{$kind};

    my ($first) = split /\n/msx, $answer->{error} // q{};

    return ( $first // q{} ) =~ s/\s+\z//rmsx;
}

sub _mojo ( $self, $url, $headers ) {
    my $tx;
    try {
        $tx = $self->user_agent->get( $url => $headers );
    }
    catch ($error) {
        return _failed( 'mojo', "$error" );
    };
    my $error = $tx->error;
    if ( $error && !defined $error->{code} ) {
        return _failed( 'mojo', $error->{message} // q{} );
    }

    return {
        client => 'mojo',
        code   => $tx->res->code,
        body   => $tx->res->body,
        error  => undef,
        kind   => undef,
    };
}

# The headers go to curl on its standard input, as a config file, never on
# its command line, where anyone on the host could read a token in ps.
sub _curl ( $self, $url, $headers ) {
    my $curl = $self->curl;
    if ( !defined $curl ) {
        return {
            client => 'curl',
            error  => 'no curl to ask an https address with',
            kind   => 'unsupported',
        };
    }

    my $body    = File::Temp->new;
    my @command = (
        $curl, qw(--silent --show-error --config -),
        '--max-time'  => $self->timeout,
        '--output'    => $body->filename,
        '--write-out' => '%{http_code}',
    );
    my $config = join q{}, map { _curl_line( header => "$_: $headers->{$_}" ) }
      sort keys %{$headers};
    $config .= _curl_line( url => $url );

    my $stderr = gensym;
    my $pid    = open3( my $stdin, my $stdout, $stderr, @command );
    print {$stdin} $config or croak "cannot write to curl: $OS_ERROR";
    close $stdin           or croak "cannot write to curl: $OS_ERROR";
    my $code    = do { local $INPUT_RECORD_SEPARATOR = undef; <$stdout> };
    my $message = do { local $INPUT_RECORD_SEPARATOR = undef; <$stderr> };
    waitpid $pid, 0;
    my $exit = $CHILD_ERROR >> $EXIT_SHIFT;

    if ($exit) {
        $message //= q{};
        $message =~ s/\A curl: \s* [(] \d+ [)] \s*//msx;
        $message =~ s/\s+\z//msx;
        return {
            client => 'curl',
            error  => $message,
            kind   => exists $CURL_KIND{$exit} ? $CURL_KIND{$exit} : 'other',
        };
    }

    return {
        client => 'curl',
        code   => 0 + ( $code // 0 ),
        body   => path( $body->filename )->slurp,
        error  => undef,
        kind   => undef,
    };
}

sub _failed ( $client, $message ) {
    my ($kind) = map { $_->[0] } grep { $message =~ $_->[1] } @MOJO_KIND;

    return {
        client => $client,
        error  => $message,
        kind   => $kind // 'other',
    };
}

# A line of a curl config file: the value double-quoted, with \ and "
# escaped, as curl reads it.
sub _curl_line ( $name, $value ) {
    $value =~ s/(["\\])/\\$1/gmsx;

    return qq{$name = "$value"\n};
}

sub _on_path ($name) {
    for my $directory ( split /:/msx, $ENV{PATH} // q{} ) {
        next if !length $directory;
        my $candidate = "$directory/$name";
        return $candidate if -x $candidate && !-d $candidate;
    }

    return undef;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::HttpProbe - One GET, and why it got no
answer.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $answer = GPForum::Service::Operations::HttpProbe->new->get(
        'http://127.0.0.1:8080/health/ready',
        { 'X-GPForum-Metrics-Token' => $token },
    );
    say $answer->{code} // $answer->{kind};

=head1 DESCRIPTION

Asks a URL once, with a short timeout and no redirects, and says what came
back: the status and body, or the error and its kind -- C<refused>,
C<unresolved>, C<timeout>, C<tls>, C<unsupported> or C<other> -- so a check
can choose the sentence an operator reads. Plain HTTP and C<http+unix>
go through L<Mojo::UserAgent>; https goes through it when
L<IO::Socket::SSL> is installed, and otherwise through C<curl>, which
verifies the certificate. Headers reach curl on its standard input, never
its command line.

=head1 SUBROUTINES/METHODS

=head2 timeout

Seconds to wait to connect and for the answer; 5 by default.

=head2 user_agent

The L<Mojo::UserAgent> used for plain HTTP.

=head2 curl

The curl program used for https, or undef when there is none on the
C<PATH>.

=head2 can_tls

Whether L<Mojo::UserAgent> speaks https on this host, which it does with
L<IO::Socket::SSL> installed; https goes through curl otherwise.

=head2 get

Takes a URL and a hash reference of headers. Returns a hash reference with
C<client>, and either C<code> and C<body> or C<error> and C<kind>.

=head2 reason

Takes what L</get> returned and a L<GPForum::Service::I18N::CliCatalog>,
and returns why there was no answer as an operator reads it.

=head1 DIAGNOSTICS

Croaks only when curl's standard input cannot be written.

=head1 CONFIGURATION AND ENVIRONMENT

Looks for curl on C<PATH>.

=head1 DEPENDENCIES

L<Mojo::UserAgent>, L<Mojo::IOLoop::TLS>, L<IPC::Open3>, L<File::Temp>, and
curl for https without L<IO::Socket::SSL>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

An https address on a host with neither IO::Socket::SSL nor curl comes back
C<unsupported>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
