# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::File qw(path);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Config::EnvironmentFile;
use GPForum::Config::Report;

our $VERSION = '0.001';

# deploy/gpforum.env.example is every setting, for the operator who needs one
# more than gpforum setup wrote (walkthrough step 9: no template shipped, the
# keys were in prose). It is generated from the settings table, so a setting
# added, renamed or retired there fails here until the file is regenerated.
# The file setup writes holds the decisions alone: t/612.

const my $EXAMPLE      => 'deploy/gpforum.env.example';
const my $SECRET       => 'f' x 64;
const my $STATUS_SHIFT => 8;

const my @DECISIONS => qw(
  GPFORUM_ENV GPFORUM_PUBLIC_BASE_URL GPFORUM_SESSION_SECRET
  GPFORUM_DATABASE_DSN GPFORUM_DATABASE_USER GPFORUM_DATABASE_PASSWORD
  GPFORUM_METRICS_TOKEN GPFORUM_MAIL_TRANSPORT GPFORUM_MAIL_FROM
  GPFORUM_ANTIVIRUS
);

my $shipped  = path($EXAMPLE)->slurp;
my $settings = GPForum::Config->settings;

is( $shipped, GPForum::Config::EnvironmentFile->render_reference,
        "$EXAMPLE is what the settings table renders; regenerate it as its"
      . ' header says' );

my %assigned = map { $_ => 1 } $shipped =~ /^ (GPFORUM_\w+) = /gmsx;
my %advanced = map { $_ => 1 } $shipped =~ /^ [#] (GPFORUM_\w+) = /gmsx;
is_deeply(
    [ sort keys %assigned ],
    [ sort @DECISIONS ],
    'the ten decisions are the uncommented lines'
);
is_deeply(
    [ sort keys %assigned, keys %advanced ],
    [ sort map { $_->{env} } grep { !$_->{retired} } @{$settings} ],
    'every other current setting is there once, commented out'
);
is_deeply(
    [
        grep { $assigned{ $_->{env} } || $advanced{ $_->{env} } }
        grep { $_->{retired} } @{$settings}
    ],
    [],
    'a retired setting is not offered'
);
is_deeply(
    [
        map  { $_->{env} }
        grep { index( $shipped, "# $_->{summary}\n" ) < 0 }
        grep { !$_->{retired} } @{$settings}
    ],
    [],
    'each with its one-line summary'
);

# Filled in as the header says -- the secrets generated, the forum's own
# address in place of the examples -- the file is a configuration production
# accepts, read the way a shell sources it.
my %read = _sourced( $shipped =~
      s/^ (GPFORUM_(?:SESSION_SECRET|METRICS_TOKEN)) = $/$1=$SECRET/grmsx );
is(
    $read{GPFORUM_DATABASE_DSN},
    'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432',
    'a shell reads the data source whole, semicolons and all'
);
lives_ok {
    GPForum::Config->from_environment(
        {
            %read,
            GPFORUM_PUBLIC_BASE_URL => 'https://forum.gpforum.test',
            GPFORUM_MAIL_FROM       => 'forum@forum.gpforum.test',
        }
    )
}
'with its secrets generated and its own address, the template is a'
  . ' production configuration';

# Left with the examples, it is not: production names both placeholders,
# and nothing else.
throws_ok { GPForum::Config->from_environment( \%read ) }
'GPForum::X::Config', 'the examples left as copied stop production';
is_deeply(
    [ map { [ $_->{variable}, $_->{key} ] } @{ $EVAL_ERROR->problems } ],
    [
        [ GPFORUM_PUBLIC_BASE_URL => 'config.placeholder_url' ],
        [ GPFORUM_MAIL_FROM       => 'config.placeholder_mail_from' ],
    ],
    'the address and the sender, each as the example it is'
);

# The report of a wrong setting writes its example as a line to paste into
# the same file, so a shell must read each one whole too:
# GPFORUM_ANTIVIRUS_COMMAND=clamscan --no-summary, bare, would run
# --no-summary instead.
my %example = map { $_->{env} => $_->{example} }
  grep { defined $_->{example} } @{ GPForum::Config->settings };
my %pasted = _sourced(
    join q{},
    map { GPForum::Config::Report->assignment( $_, $example{$_} ) . "\n" }
      sort keys %example
);
is_deeply( \%pasted, \%example,
    'every example the report gives reads back whole from the file' );

done_testing();

# The GPFORUM_ variables a POSIX shell sets when it sources the text with
# `set -a`, as the FreeBSD rc script and the documented manual commands do.
sub _sourced ($text) {
    my $file = path( tempdir( CLEANUP => 1 ), 'gpforum.env' );
    $file->spew($text);
    delete local @ENV{ grep { /\A GPFORUM_/msx } keys %ENV };
    my $pid =
      open3( my $input, my $output, undef, '/bin/sh', '-c',
        'set -a; . "$1"; env',
        'sh', "$file" );
    close $input or return;
    my %variables =
      map { split /=/msx, $_, 2 } grep { /\A GPFORUM_/msx } split /\n/msx,
      do { local $INPUT_RECORD_SEPARATOR = undef; <$output> };
    waitpid $pid, 0;

    return %variables;
}

1;
