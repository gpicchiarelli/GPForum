# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Doctor;
use GPForum::Service::Operations::Findings;
use GPForum::Test::NoServiceUnits;

our $VERSION = '0.001';

# Walkthrough 2, frictions 6, 7 and 13: what gpforum doctor says, said as
# its other lines say it.
#
# - The failing database line read "✗ Cannot reach PostgreSQL at ...", where
#   every other line opens with its name ("✓ database: PostgreSQL 18.6").
# - A port that answers plain HTTP read "no TLS handshake with URL:
#   LibreSSL/3.3.6: error:1404B42E:SSL routines:..."; the library's words
#   belong under the sentence, on a Detail: line, as the antivirus check
#   writes the scanner's.
# - An invalid setting was quoted as it was, a password inside it included,
#   and so was the DBI error of a database failure doctor does not know.

const my $SECRET => '0123456789abcdef' x 4;
const my $FILE   => '/etc/gpforum/gpforum.env';
const my %PRODUCTION => (
    GPFORUM_ENV             => 'production',
    GPFORUM_MAIL_FROM       => 'forum@forum.gpforum.net',
    GPFORUM_METRICS_TOKEN   => 'metrics-token',
    GPFORUM_PUBLIC_BASE_URL => 'https://forum.gpforum.net',
    GPFORUM_SESSION_SECRET  => $SECRET,
);
const my $REFUSED => q{DBI connect('dbname=gpforum;host=127.0.0.1;port=5432',}
  . q{'gpforum',...) failed: connection to server at "127.0.0.1", port 5432}
  . ' failed: Connection refused';
const my $UNKNOWN_HOST =>
  q{DBI connect('dbname=gpforum;host=db.invalid;port=5432','gpforum',...)}
  . ' failed: could not translate host name "db.invalid" to address: Name'
  . ' or service not known';
const my $ODD => q{DBI connect('dbname=gpforum;host=db;password=hunter2',}
  . q{'gpforum',...) failed: the server sent something odd};
const my $LIBRESSL => 'LibreSSL/3.3.6: error:1404B42E:SSL routines:'
  . 'ST_CONNECT:tlsv1 alert protocol version';

subtest 'the failing database line opens with its name' => sub {
    my $refused = _text( database => _dies($REFUSED) );
    _has(
        $refused,
        "\N{BALLOT X} database: cannot reach PostgreSQL at 127.0.0.1:5432"
          . " (connection refused)\n",
        'database:, then the sentence, its first word lowercased'
    );
    _has(
        _text( database => _dies($UNKNOWN_HOST) ),
        "\N{BALLOT X} database: cannot find the PostgreSQL host db.invalid\n",
        'whichever sentence it is'
    );

    my $italian = _text(
        database => _dies($REFUSED),
        language => 'it'
    );
    _has(
        $italian,
        "\N{BALLOT X} database: PostgreSQL non risponde su 127.0.0.1:5432"
          . " (connessione rifiutata)\n",
        'and a name keeps its capitals, in Italian'
    );
    _has(
        _text( database => _dies($UNKNOWN_HOST), language => 'it' ),
        "\N{BALLOT X} database: l'host PostgreSQL db.invalid non esiste\n",
        'where an article is lowercased'
    );
};

subtest 'a failed TLS handshake is a sentence, and the library a detail' =>
  sub {
    my $text = _text(
        address => sub {
            return { error => $LIBRESSL, kind => 'handshake' };
        }
    );
    _has(
        $text,
        "! address: no TLS handshake with https://forum.gpforum.net\n"
          . "    Detail: $LIBRESSL\n",
        'the sentence ends at the address, the library under it'
    );
    unlike(
        $text,
        qr/^[!] [^\n]* LibreSSL/msx,
        'and the line itself does not quote it'
    );
    _has(
        _text(
            address => sub {
                return { error => $LIBRESSL, kind => 'handshake' };
            },
            language => 'it'
        ),
        "! indirizzo: nessun handshake TLS con https://forum.gpforum.net\n"
          . "    Dettaglio: $LIBRESSL\n",
        'in Italian too'
    );
  };

subtest 'no password is quoted' => sub {
    my $doctor = _doctor();
    for my $case (
        [
            'a DSN in the wrong setting',
            'dbi:Pg:dbname=gpforum;host=db;password=hunter2'
        ],
        [ 'credentials in a URL', 'http://admin:hunter2@forum.gpforum.net' ],
      )
    {
        my ( $name, $value ) = @{$case};
        my $findings =
          GPForum::Service::Operations::Findings->new(
            catalog => $doctor->catalog );
        $doctor->settings( { %PRODUCTION, GPFORUM_PUBLIC_BASE_URL => $value },
            $findings );
        my $text = $findings->human_text;
        like( $text, qr/GPFORUM_PUBLIC_BASE_URL/msx, "$name is refused" );
        unlike( $text, qr/hunter2/msx, 'without its password' );
        like( $text, qr/\[redacted\]/msx, 'which is shown as redacted' );
    }

    my $odd = _text( database => _dies($ODD) );
    like(
        $odd,
        qr/database: [ ] it [ ] cannot [ ] be [ ] used/msx,
        'a database failure doctor does not know is quoted'
    );
    unlike( $odd, qr/hunter2/msx, 'without the password in its DSN' );
};

done_testing();

sub _text (%replace) {
    return _doctor(%replace)->check->{findings}->human_text;
}

# A production doctor on doubles for every probe, a healthy Debian host
# unless a test replaces one.
sub _doctor (%replace) {
    my $language = delete $replace{language} // 'en';
    my %probes   = (
        address   => sub { return { code   => 200 } },
        antivirus => sub { return { status => 'disabled', engine => 'none' } },
        budgets   =>
          sub { return { missing => [], extra => [], mismatched => [] } },
        database => sub { return { schema => {}, version => '18.6' } },
        mail     => sub {
            return { status => 'pass', probe => { action => 'log_transport' } };
        },
        outbox    => sub { return { waiting => 0 } },
        preflight => sub {
            return {
                checks => [],
                os     =>
                  { name => 'linux', event_backend => 'epoll', cpu_count => 2 },
                resources => {},
                runtime   => {},
            };
        },
        readiness => sub { return { status => 'ok',  checks  => [] } },
        schema    => sub { return { latest => '051', pending => [] } },
        tls       => sub { return 1 },
        %replace,
    );

    return GPForum::Service::Operations::Doctor->new(
        catalog =>
          GPForum::Service::I18N::CliCatalog->new( language => $language ),
        environment => {%PRODUCTION},
        file        => $FILE,
        probes      => \%probes,
        os          => GPForum::OS->from_name('linux'),
        units       => GPForum::Test::NoServiceUnits->new,
    );
}

sub _dies ($message) {
    return sub { die "$message\n" };
}

sub _has ( $text, $literal, $name ) {
    return ok( index( $text, $literal ) >= 0, $name ) || diag $text;
}

1;
