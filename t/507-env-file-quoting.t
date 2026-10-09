# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::File qw(path);
use Mojo::Util qw(decode encode);
use Test::More;

use lib 'lib';

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Config::EnvironmentFile;
use GPForum::Config::Report;

our $VERSION = '0.001';

# One environment file is read three ways: by systemd (EnvironmentFile=), by
# a POSIX shell (the FreeBSD rc script sources it) and by gpforum itself, the
# front door (ADR 0120). A password with $, quotes or spaces written bare read
# differently under each (walkthrough 1, friction 16). The template's header
# now gives the rule -- bare for a plain word, else double quotes with \ " $
# and ` escaped, the form GPForum::Config::Report writes -- and this holds the
# three readers to it.
#
# This host runs no systemd: its reader below follows the rules systemd.exec(5)
# gives for EnvironmentFile=, and only for one-line values.

const my @PASSWORDS => (
    'p@ss$word',
    'my $ecret "pass" word',
    q{it's a 'quote'},
    'back\\slash and \\$ too',
    'semi;colon #hash',
    '  spaced out  ',
    '$(echo ran) `echo ran` ${HOME}',
"p\N{LATIN SMALL LETTER A WITH DIAERESIS}ssw\N{LATIN SMALL LETTER O WITH DIAERESIS}rd",
    'plain-word_1.2/3:4@5,6+7%8=9',
);

subtest 'what the rule writes, every reader reads back' => sub {
    my %written =
      map { ( "GPFORUM_TEST_$_" => $PASSWORDS[$_] ) } 0 .. $#PASSWORDS;
    my $file = join q{},
      map { GPForum::Config::Report->assignment( $_, $written{$_} ) . "\n" }
      sort keys %written;

    is_deeply( { _sourced($file) }, \%written, 'a shell sourcing the file' );
    is_deeply( { _systemd($file) },
        \%written, q{systemd's EnvironmentFile= rules} );
    is_deeply( { _front_door($file) }, \%written, 'gpforum, the front door' );
};

subtest q{the template's example reads as it says} => sub {
    my ($line) = GPForum::Config::EnvironmentFile->render_reference =~
      /^ [#] \s+ (GPFORUM_DATABASE_PASSWORD="[^\n]+) $/msx;
    ok( defined $line, 'the header shows a quoted password' );
    my $expected = { GPFORUM_DATABASE_PASSWORD => 'my $ecret "pass" word' };
    is_deeply( { _sourced("$line\n") },    $expected, 'to a shell' );
    is_deeply( { _systemd("$line\n") },    $expected, 'to systemd' );
    is_deeply( { _front_door("$line\n") }, $expected, 'to gpforum' );
};

subtest 'single quotes read the same, for a value without one' => sub {
    my $line     = q{GPFORUM_SMTP_PASSWORD='p@ss $word "x" \\ ;#'} . "\n";
    my $expected = { GPFORUM_SMTP_PASSWORD => 'p@ss $word "x" \\ ;#' };
    is_deeply( { _sourced($line) },    $expected, 'to a shell' );
    is_deeply( { _systemd($line) },    $expected, 'to systemd' );
    is_deeply( { _front_door($line) }, $expected, 'to gpforum' );
};

subtest 'left bare, the readers disagree: why the rule is there' => sub {
    my $line    = 'GPFORUM_SMTP_PASSWORD=pa$s word' . "\n";
    my %systemd = _systemd($line);
    is( $systemd{GPFORUM_SMTP_PASSWORD},
        'pa$s word', 'systemd keeps the whole line' );
    my %shell = _sourced($line);
    isnt( $shell{GPFORUM_SMTP_PASSWORD} // q{},
        'pa$s word', 'a shell does not' );
};

# Bare, a backslash keeps the character after it and is itself dropped, by
# systemd and by a shell alike. gpforum kept it: a password written ab\cd
# reached the database as ab\cd from gpforum migrate and as abcd from the
# service (settings review).
subtest 'a backslash in a bare value reads the same everywhere' => sub {
    my %expected = (
        GPFORUM_TEST_A => 'abcd',
        GPFORUM_TEST_B => 'a b c',
        GPFORUM_TEST_C => 'p$w',
        GPFORUM_TEST_D => 'back\\slash',
    );
    my $file = join "\n", 'GPFORUM_TEST_A=ab\\cd', 'GPFORUM_TEST_B=a\\ b\\ c',
      'GPFORUM_TEST_C=p\\$w', 'GPFORUM_TEST_D=back\\\\slash', q{};

    is_deeply( { _sourced($file) },    \%expected, 'a shell' );
    is_deeply( { _systemd($file) },    \%expected, q{systemd's rules} );
    is_deeply( { _front_door($file) }, \%expected, 'gpforum' );
};

done_testing();

# The GPFORUM_ variables a POSIX shell sets when it sources the text with
# `set -a`, as the FreeBSD rc script does. The shell is told nothing else to
# run, so a value that would run a command when unquoted is caught by
# comparing what it read.
sub _sourced ($text) {
    my $file = path( tempdir( CLEANUP => 1 ), 'gpforum.env' );
    $file->spew( encode( 'UTF-8', $text ) );
    delete local @ENV{ grep { /\A GPFORUM_/msx } keys %ENV };
    my $pid =
      open3( my $input, my $output, undef, '/bin/sh', '-c',
        'set -a; . "$1" 2>/dev/null; env',
        'sh', "$file" );
    close $input or return;
    my $printed = do { local $INPUT_RECORD_SEPARATOR = undef; <$output> };
    waitpid $pid, 0;

    return map { split /=/msx, $_, 2 } grep { /\A GPFORUM_/msx } split /\n/msx,
      decode( 'UTF-8', $printed );
}

sub _front_door ($text) {
    return map { @{$_} }
      grep { ref }
      map  { GPForum::Command::Support::ServiceEnvironment->parse_line($_) }
      split /^/msx, $text;
}

sub _systemd ($text) {
    my %read;
    for my $line ( split /\n/msx, $text ) {
        next if $line =~ /\A \s* (?: [#;] | \z )/msx;
        my ( $name, $rest ) = $line =~ /\A \s* (\w+) = (.*) \z/msx;
        next if !defined $name;
        $read{$name} = _systemd_value($rest);
    }

    return %read;
}

# systemd.exec(5), EnvironmentFile=: leading whitespace is dropped; a value
# in single quotes is taken verbatim; in double quotes a backslash before
# one of " \ ` $ keeps that character, and before any other keeps both;
# unquoted, a backslash keeps the character after it, interior whitespace
# is kept and trailing whitespace is dropped.
sub _systemd_value ($text) {
    $text =~ s/\A [ \t]+//msx;
    if ( $text =~ /\A ' ([^']*) ' /msx ) {
        return $1;
    }

    my @characters = split //msx, $text;
    my $value      = q{};
    if ( @characters && $characters[0] eq q{"} ) {
        my $at = 1;
        while ( $at < @characters && $characters[$at] ne q{"} ) {
            if ( $characters[$at] eq q{\\} && $at + 1 < @characters ) {
                my $next = $characters[ $at + 1 ];
                $value .= $next =~ /\A ["\\`\$] \z/msx ? $next : "\\$next";
                $at += 2;
                next;
            }
            $value .= $characters[ $at++ ];
        }
        return $value;
    }

    my $at = 0;
    while ( $at < @characters ) {
        if ( $characters[$at] eq q{\\} && $at + 1 < @characters ) {
            $value .= $characters[ $at + 1 ];
            $at += 2;
            next;
        }
        $value .= $characters[ $at++ ];
    }
    $value =~ s/[ \t\r]+\z//msx;

    return $value;
}

1;
