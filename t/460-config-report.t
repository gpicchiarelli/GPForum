# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use IPC::Open3 qw(open3);
use Mojo::Util qw(decode);
use Symbol     qw(gensym);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Config;
use GPForum::Config;
use GPForum::Config::Report;
use GPForum::Service::I18N::CliCatalog;
use GPForum::X::Config;

our $VERSION = '0.001';

# sysexits.h's EX_CONFIG.
const my $EX_CONFIG    => 78;
const my $STATUS_SHIFT => 8;

# A production environment with three things wrong at once, as the walkthrough
# met them one restart at a time (docs/ops/evidence/2026-10-07-operator-
# walkthrough, section 4.1): no session secret, no metrics token, and an
# environment name that is not one.
const my %THREE_WRONG => (
    GPFORUM_ENV             => 'production',
    GPFORUM_PUBLIC_BASE_URL => 'https://forum.example.test',
    GPFORUM_MAIL_FROM       => 'forum@forum.example.test',
    GPFORUM_LOG_LEVEL       => 'verbose',
);

subtest 'every problem is reported at once, naming its variable' => sub {
    my $error =
      _refusal( sub { GPForum::Config->from_environment( \%THREE_WRONG ) } );
    ok( GPForum::X::Config->caught($error), 'one configuration error' );
    is_deeply(
        [ map { $_->{variable} } @{ $error->problems } ],
        [qw(GPFORUM_LOG_LEVEL GPFORUM_SESSION_SECRET GPFORUM_METRICS_TOKEN)],
        'carrying all three problems, in the order of the settings table'
    );
    my $report = "$error";
    like(
        $report,
        qr/\A GPForum's [ ] settings [ ] need [ ] attention: \n\n/msx,
        'the report opens by saying the settings need attention'
    );
    for my $line (
          q{  GPFORUM_LOG_LEVEL must be one of trace, debug, info, warn, error,}
        . q{ fatal, not 'verbose'.},
        '    Example: GPFORUM_LOG_LEVEL=info',
        '  GPFORUM_SESSION_SECRET is required in production.',
        '    Generate one with: openssl rand -hex 32',
        '  GPFORUM_METRICS_TOKEN is required in production.',
      )
    {
        like( $report, qr/^ \Q$line\E $/msx, "it reads: $line" );
    }
    like(
        $report,
        qr/deploy\/gpforum[.]env[.]example .* try [ ] again[.] \n \z/msx,
        'and closes on where to set them, ending in a newline'
    );
    unlike(
        $report,
        qr/\b (?:session_secret|metrics_token|log_level) \b/msx,
        'no attribute name stands in for a variable'
    );
};

subtest 'a value that does not parse is one problem among the others' => sub {
    my $error = _refusal(
        sub {
            GPForum::Config->from_environment(
                {
                    GPFORUM_SMTP_PORT       => 'twenty-five',
                    GPFORUM_RUNTIME_LISTEN  => '8080',
                    GPFORUM_DEFAULT_LOCALE  => 'fr',
                    GPFORUM_RUNTIME_BACKLOG => '-3',
                }
            );
        }
    );
    is_deeply(
        [ map { $_->{variable} } @{ $error->problems } ],
        [
            qw(GPFORUM_DEFAULT_LOCALE GPFORUM_RUNTIME_LISTEN
              GPFORUM_RUNTIME_BACKLOG GPFORUM_SMTP_PORT)
        ],
        'the unreadable numbers and the refused values are listed together'
    );
};

subtest 'every problem names a variable an operator can set' => sub {
    my %read = map { $_->{env} => 1 } @{ GPForum::Config->settings };
    my ( @problems, $cases, $refused );
    for my $case (
        { GPFORUM_ENV              => 'prod' },
        { GPFORUM_WEB_PROCESSES    => 'lots' },
        { GPFORUM_RUNTIME_PROXY    => 'maybe' },
        { GPFORUM_MINION_ENABLED   => 'on' },
        { GPFORUM_GLIFISTORE_URL   => 'redis://cache' },
        { GPFORUM_ANTIVIRUS        => 'command' },
        { GPFORUM_DEFAULT_TIMEZONE => 'Moon/Base' },
        {
            GPFORUM_RUNTIME_TRUSTED_PROXIES => q{,},
            GPFORUM_RUNTIME_PROXY           => 'on'
        },
        { GPFORUM_MAIL_TRANSPORT => 'smtp' },
      )
    {
        my $error =
          _refusal( sub { GPForum::Config->from_environment($case) } );
        $cases++;
        if ($error) {
            $refused++;
        }
        push @problems, @{ $error ? $error->problems : [] };
    }
    is( $refused, $cases, 'each case is refused' );
    is_deeply( [ grep { !$read{ $_->{variable} } } @problems ],
        [], 'and every refusal names a GPFORUM_ variable Config reads' );
    is_deeply(
        [
            grep {
                GPForum::Config::Report->sentence($_) !~
                  /\A \Q$_->{variable}\E\b/msx
            } @problems
        ],
        [],
        'which is the first word of its sentence'
    );
};

subtest 'bin/gpforum stops with EX_CONFIG and the whole report' => sub {
    my $english = _start( { %THREE_WRONG, LC_ALL => 'en_US.UTF-8' } );
    is( $english->{status}, $EX_CONFIG, 'exit status 78, EX_CONFIG' );
    is( $english->{output}, q{},        'nothing on standard output' );
    my $problems =
      _refusal( sub { GPForum::Config->from_environment( \%THREE_WRONG ) } )
      ->problems;
    is(
        $english->{errors},
        GPForum::Config::Report->render($problems),
        'the report, all of it, on standard error'
    );

    my $italian =
      _start( { %THREE_WRONG, LC_ALL => q{}, LANG => 'it_IT.UTF-8' } );
    is( $italian->{status}, $EX_CONFIG, 'in Italian too, exit status 78' );
    my $text = decode( 'UTF-8', $italian->{errors} );
    ok( defined $text, 'the Italian report is UTF-8' );
    is(
        $text,
        GPForum::Service::I18N::CliCatalog->new( language => 'it' )
          ->config_report($problems),
        'and reads in Italian when LANG asks for it'
    );
    like(
        $text // q{},
        qr/\A Le [ ] impostazioni [ ] di [ ] GPForum/msx,
        'from its first words'
    );
};

# The commands report a configuration they cannot use through
# Command::Usage->failure: the same report, in the same language, and
# EX_CONFIG, 78, as bin/gpforum (ADR 0120).
subtest 'a bin/gpforum-* command reports it the same way' => sub {
    my $problems =
      _refusal( sub { GPForum::Config->from_environment( \%THREE_WRONG ) } )
      ->problems;
    my $italian =
      _start( { %THREE_WRONG, LC_ALL => q{}, LANG => 'it_IT.UTF-8' },
        'bin/gpforum-os-preflight' );
    is( $italian->{status}, $EX_CONFIG, 'exit status 78, EX_CONFIG' );
    is( $italian->{output}, q{},        'nothing on standard output' );
    is(
        decode( 'UTF-8', $italian->{errors} ),
        GPForum::Service::I18N::CliCatalog->new( language => 'it' )
          ->config_report($problems),
        'the whole report, in Italian, as UTF-8'
    );
};

subtest q{Bootstrap::Config loads a good one and keeps a bad one's problems} =>
  sub {
    my $loaded = GPForum::Bootstrap::Config->load( { GPFORUM_ENV => 'test' } );
    is( $loaded->environment, 'test', 'a configuration with no problem loads' );

    my $error = _refusal(
        sub { GPForum::Bootstrap::Config->load( { GPFORUM_ENV => 'prod' } ) } );
    is_deeply( [ map { $_->{variable} } @{ $error->problems } ],
        ['GPFORUM_ENV'], 'a refused one keeps its problems for a reader' );
  };

done_testing();

sub _refusal ($code) {
    try {
        $code->();
    }
    catch ($error) {
        return $error;
    };

    return undef;
}

# bin/gpforum version, or the command given, started as an operator starts
# it, without a shell, with only the given variables of GPForum's own and of
# the locale.
sub _start ( $environment, @command ) {
    if ( !@command ) {
        @command = ( 'bin/gpforum', 'version' );
    }
    my %clean = map { $_ => $ENV{$_} }
      grep { !/\A (?:GPFORUM_|LC_|LANG\z)/msx } keys %ENV;
    my ( $pid, $output, $errors );
    {
        local %ENV = ( %clean, %{$environment} );
        $errors = gensym;
        $pid    = open3( my $input, $output, $errors, $EXECUTABLE_NAME, '-Ilib',
            @command );
        close $input or croak "close child input: $ERRNO";
    }
    my %read;
    for my $stream ( [ output => $output ], [ errors => $errors ] ) {
        local $INPUT_RECORD_SEPARATOR = undef;
        my $handle = $stream->[1];
        $read{ $stream->[0] } = <$handle> // q{};
    }
    waitpid $pid, 0;

    return { %read, status => $CHILD_ERROR >> $STATUS_SHIFT };
}

1;
