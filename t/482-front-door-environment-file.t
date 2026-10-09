# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::File qw(path);
use Symbol     qw(gensym);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::OS;
use GPForum::Service::Operations::DatabaseFailure;
use GPForum::X::Config;

our $VERSION = '0.001';

const my $EX_CONFIG     => 78;
const my $STATUS_SHIFT  => 8;
const my $SECRET_LENGTH => 64;
const my $REFUSED => 'DBI connect(\'dbname=gpforum;host=127.0.0.1\','
  . '\'gpforum\',...) failed: connection to server at "127.0.0.1", port 5432'
  . ' failed: Connection refused';

# B1, ADR 0120: bin/gpforum reads the environment file the service reads, so
# a command typed by hand sees the service's settings without `set -a; .
# /etc/gpforum/gpforum.env`. The process environment wins over the file.

const my $SERVICE => 'GPForum::Command::Support::ServiceEnvironment';

my $directory = tempdir( CLEANUP => 1 );

subtest 'a line reads as systemd and a shell read it' => sub {
    for my $case (
        [ 'GPFORUM_ENV=production',        [ 'GPFORUM_ENV', 'production' ] ],
        [ "GPFORUM_ENV=production\r\n",    [ 'GPFORUM_ENV', 'production' ] ],
        [ '  GPFORUM_ENV = production   ', [ 'GPFORUM_ENV', 'production' ] ],
        [ 'export GPFORUM_ENV=staging',    [ 'GPFORUM_ENV', 'staging' ] ],
        [ 'GPFORUM_DATABASE_PASSWORD=', [ 'GPFORUM_DATABASE_PASSWORD', q{} ] ],
        [ q{GPFORUM_X='a b $c'},           [ 'GPFORUM_X', 'a b $c' ] ],
        [ q{GPFORUM_X="a \"b\" \\\\ \$c"}, [ 'GPFORUM_X', 'a "b" \\ $c' ] ],
        [ q{GPFORUM_X="keep \n as is"},    [ 'GPFORUM_X', 'keep \n as is' ] ],
        [
            q{GPFORUM_DATABASE_DSN="dbi:Pg:dbname=gpforum;host=127.0.0.1"},
            [ 'GPFORUM_DATABASE_DSN', 'dbi:Pg:dbname=gpforum;host=127.0.0.1' ]
        ],
      )
    {
        my ( $line, $expected ) = @{$case};
        is_deeply( $SERVICE->parse_line($line), $expected, "reads [$line]" );
    }
    for my $ignored ( q{}, q{ } x 2, '# a comment', '#GPFORUM_ENV=production',
        '; also a comment' )
    {
        is( $SERVICE->parse_line($ignored), undef, "ignores [$ignored]" );
    }
    for my $malformed (
        'not an assignment',       q{GPFORUM_X="open},
        q{GPFORUM_X='a' trailing}, '9GPFORUM=x'
      )
    {
        is( $SERVICE->parse_line($malformed),
            q{}, "says [$malformed] is not an assignment" );
    }
};

subtest 'the file fills what the environment does not set' => sub {
    my $file = _file( 'filled.env', <<'TEXT' );
# GPForum's environment file.
GPFORUM_ENV=production
GPFORUM_PUBLIC_BASE_URL=https://forum.example.org

GPFORUM_DATABASE_USER=gpforum_app
TEXT
    my %environment = ( GPFORUM_ENV => 'development' );
    my $loaded      = $SERVICE->new(
        environment => \%environment,
        file        => $file
    )->load;
    is( $loaded->{file}, $file, 'the file read is named' );
    is( $environment{GPFORUM_ENV},
        'development', 'a name the environment already has keeps its value' );
    is( $environment{GPFORUM_PUBLIC_BASE_URL},
        'https://forum.example.org', 'one it lacks takes the file value' );
    is_deeply(
        [ sort @{ $loaded->{set} } ],
        [qw(GPFORUM_DATABASE_USER GPFORUM_PUBLIC_BASE_URL)],
        'and the load says which it set'
    );
    is_deeply( $loaded->{kept}, ['GPFORUM_ENV'],
        'and which the environment kept' );
    is( $SERVICE->loaded, $file, 'the process remembers the file it read' );
};

subtest 'a name assigned twice takes its last value, as the service does' =>
  sub {
    my $file = _file( 'twice.env', <<'TEXT' );
GPFORUM_DATABASE_DSN="dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432"
GPFORUM_ENV=development
GPFORUM_DATABASE_DSN="dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5433"
GPFORUM_ENV=production
TEXT
    my %environment = ( GPFORUM_ENV => 'staging' );
    my $loaded      = $SERVICE->new(
        environment => \%environment,
        file        => $file
    )->load;
    is(
        $environment{GPFORUM_DATABASE_DSN},
        'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5433',
        'the later line wins, as systemd and sh read the file'
    );
    is( $environment{GPFORUM_ENV},
        'staging', 'and neither line replaces what the process held' );
    is_deeply( $loaded->{set}, ['GPFORUM_DATABASE_DSN'],
        'each name is set once' );
    is_deeply( $loaded->{kept}, ['GPFORUM_ENV'], 'and kept once' );
  };

subtest 'without a file there is nothing to read' => sub {
    my %environment = ( GPFORUM_ENV => 'development' );
    my $service     = $SERVICE->new(
        environment => \%environment,
        os          => GPForum::OS->from_name('linux'),
    );
    if ( -e $service->default_file ) {
        plan skip_all => 'this host has ' . $service->default_file;
    }
    my $loaded = $service->load;
    is( $loaded->{file}, undef, 'no file is read' );
    is_deeply(
        \%environment,
        { GPFORUM_ENV => 'development' },
        'and the environment is as it was'
    );
};

subtest 'each host has its file' => sub {
    is( $SERVICE->new( os => GPForum::OS->from_name('linux') )->default_file,
        '/etc/gpforum/gpforum.env', 'Linux reads /etc' );
    is(
        $SERVICE->new( os => GPForum::OS->from_name('freebsd') )->default_file,
        '/usr/local/etc/gpforum/gpforum.env',
        'FreeBSD reads /usr/local/etc, as ports do'
    );
    {
        local $ENV{HOMEBREW_PREFIX} = '/opt/brew';
        is(
            $SERVICE->new( os => GPForum::OS->from_name('darwin') )
              ->default_file,
            '/opt/brew/etc/gpforum/gpforum.env',
            q{macOS reads Homebrew's prefix}
        );
        is(
            GPForum::Service::Operations::DatabaseFailure->new(
                os          => GPForum::OS->from_name('darwin'),
                environment => 'production',
                language    => 'en',
            )->sentence($REFUSED),
            'Cannot reach PostgreSQL at 127.0.0.1:5432 (connection refused):'
              . ' start it with brew services start postgresql@18, or correct'
              . ' GPFORUM_DATABASE_DSN in /opt/brew/etc/gpforum/gpforum.env.',
            'and a sentence that names the file sends the operator there,'
              . ' not to the launchd plist'
        );
    }
    like(
        $SERVICE->new( os => GPForum::OS->from_name('linux') )->restart_command,
        qr/systemctl [ ] restart [ ] gpforum [ ] gpforum-outbox/msx,
        'and restarts its services its own way'
    );
    like(
        $SERVICE->new( os => GPForum::OS->from_name('darwin') )->start_command,
        qr{\A sudo [ ] launchctl [ ] bootstrap [ ] system [ ]}msx,
        'and starts them by loading what launchd has not loaded'
    );
    like(
        $SERVICE->new( os => GPForum::OS->from_name('linux') )->start_command,
        qr/systemctl [ ] enable [ ] --now [ ] gpforum [ ] gpforum-outbox/msx,
        'enabled, as the deployment guide starts them'
    );
};

subtest 'a file it cannot use is said, in a sentence' => sub {
    my $missing = "$directory/absent.env";
    my $refused = _refusal(
        sub { $SERVICE->new( environment => {}, file => $missing )->load } );
    ok( GPForum::X::Config->caught($refused), 'a missing file is refused' );
    like( "$refused", qr/There [ ] is [ ] no [ ] \Q$missing\E/msx,
        'naming it' );

    my $broken = _file( 'broken.env', "GPFORUM_ENV=production\nnonsense\n" );
    like(
        _refusal(
            sub { $SERVICE->new( environment => {}, file => $broken )->load }
        ),
        qr/Line [ ] 2 [ ] of [ ] \Q$broken\E [ ] is [ ] not [ ] NAME=value/msx,
        'a line that is not an assignment is named by number'
    );
    my %lenient;
    $SERVICE->new( environment => \%lenient, file => $broken, strict => 0 )
      ->load;
    is( $lenient{GPFORUM_ENV}, 'production',
        'the service, lenient, reads what it can' );

  SKIP: {
        if ( $EFFECTIVE_USER_ID == 0 ) {
            skip 'root reads every file', 2;
        }
        my $locked = _file( 'locked.env', "GPFORUM_ENV=production\n" );
        chmod 0, $locked or BAIL_OUT("chmod: $OS_ERROR");
        like(
            _refusal(
                sub {
                    $SERVICE->new( environment => {}, file => $locked )->load;
                }
            ),
            qr/Cannot [ ] read [ ] \Q$locked\E .* sudo [ ] -u [ ] gpforum/msx,
            'an unreadable one says whose it is to read'
        );
        my %quiet;
        is_deeply(
            $SERVICE->new(
                environment => \%quiet,
                file        => $locked,
                strict      => 0
            )->load->{set},
            [],
            'and the service leaves it to the supervisor that read it'
        );
    }
};

subtest 'wrong settings end in the file read, with EX_CONFIG' => sub {
    my $file = _file( 'wrong.env', "GPFORUM_ENV=prod\n" );
    my %environment;
    $SERVICE->new( environment => \%environment, file => $file )->load;
    my $error =
      _refusal( sub { GPForum::Config->from_environment( \%environment ) } );

    my ( $status, $errors ) =
      _stderr( sub { return GPForum::Command::Usage->failure($error) } );
    is( $status, $EX_CONFIG, 'a command stops with 78, as bin/gpforum does' );
    like(
        $errors,
        qr/\A GPForum's [ ] settings [ ] need [ ] attention:/msx,
        'reporting every problem'
    );
    like(
        $errors,
qr/^Set [ ] these [ ] in [ ] \Q$file\E, [ ] then [ ] try [ ] again[.]$/msx,
        'and naming the file this process read as the place to fix them'
    );
};

subtest 'a secret the file lacks is one gpforum secret rotate away' => sub {
    my $file = _file( 'secretless.env',
        "GPFORUM_ENV=production\nGPFORUM_SESSION_SECRET=\n" );
    my $run = _front_door( '--env-file', $file, 'migrate' );
    is( $run->{status}, $EX_CONFIG, 'the settings stop the command' );
    ok(
        index( $run->{errors},
            "Generate one with: gpforum --env-file $file secret rotate" ) >= 0,
        'and the secret is written with the front door, not openssl'
    );
    like(
        $run->{errors},
        qr/secret [ ] rotate [ ] session$/msx,
        'the session secret by its name'
    );
    like(
        $run->{errors},
        qr/secret [ ] rotate [ ] metrics$/msx,
        'as the metrics token is'
    );
};

subtest 'a database it cannot reach is corrected in the file it read' => sub {
    for my $environment (qw(development production)) {
        my $file = _file(
            "$environment-unreachable.env",
            join q{},
            map { "$_\n" } "GPFORUM_ENV=$environment",
'GPFORUM_DATABASE_DSN="dbi:Pg:dbname=gpforum;host=127.0.0.1;port=9"',
            ( 'GPFORUM_SESSION_SECRET=' . ( 'a' x $SECRET_LENGTH ) ),
            ( 'GPFORUM_METRICS_TOKEN=' . ( 'b' x $SECRET_LENGTH ) ),
            'GPFORUM_PUBLIC_BASE_URL=https://forum.gpforum.test',
            'GPFORUM_MAIL_FROM=forum@forum.gpforum.test',
            'GPFORUM_ANTIVIRUS=none',
        );
        my $run = _front_door( '--env-file', $file, 'migrate' );
        is( $run->{status}, 1, "$environment: migrate fails" );
        like(
            $run->{errors},
            qr/correct [ ] GPFORUM_DATABASE_DSN [ ] in [ ] \Q$file\E[.]$/msx,
            'naming the file it read, not the shell or the host default'
        );
    }
};

subtest 'every check reports wrong settings as every command does' => sub {
    my $file = _file( 'checked.env', "GPFORUM_ENV=prod\n" );
    for my $check (
        ['os-preflight'],
        [ 'os-preflight', '--strict', '--json' ],
        [ 'mail-check',   '--human' ],
        ['antivirus-check'],
      )
    {
        my $run = _front_door( '--env-file', $file, @{$check} );
        is( $run->{status}, $EX_CONFIG, "gpforum @{$check} stops with 78" );
        like(
            $run->{errors},
qr/^Set [ ] these [ ] in [ ] \Q$file\E, [ ] then [ ] try [ ] again[.]$/msx,
            'naming the file it read'
        );
    }
};

subtest 'gpforum mail-check answers in sentences, the old name in JSON' => sub {
    my $file = _file( 'mail.env',
        "GPFORUM_ENV=development\nGPFORUM_MAIL_TRANSPORT=log\n" );
    my $verb = _front_door( '--env-file', $file, 'mail-check' );
    is( $verb->{status}, 0, 'gpforum mail-check succeeds' );
    like(
        $verb->{output},
        qr/\A \S+ [ ] mail: [ ] written [ ] to [ ] the [ ] log/msx,
        'with the lines an operator reads, as every verb'
    );
    like(
        _front_door( '--env-file', $file, 'mail-check', '--json' )->{output},
        qr/\A [{] .* "check":"mail_delivery" /msx,
        'and the evidence with --json'
    );
    like(
        _front_door( '--env-file', $file, 'help', 'mail-check' )->{output},
qr/the [ ] lines [ ] an [ ] operator [ ] reads [ ] [(]the [ ] default[)]/msx,
        'which its help says'
    );
};

done_testing();

# bin/gpforum started as an operator starts it, GPFORUM_* cleared.
sub _front_door (@arguments) {
    my %wanted = (
        ( map { $_ => $ENV{$_} } grep { !/\A GPFORUM_/msx } keys %ENV ),
        LC_ALL => 'en_US.UTF-8',
    );
    my ( $pid, $output, $errors );
    {
        local %ENV = %wanted;
        $errors = gensym;
        $pid    = open3( my $input, $output, $errors, $EXECUTABLE_NAME,
            'bin/gpforum', @arguments );
        close $input or croak "close child input: $OS_ERROR";
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

sub _file ( $name, $text ) {
    my $file = path( $directory, $name );
    $file->spew($text);

    return $file->to_string;
}

sub _refusal ($code) {
    try {
        $code->();
    }
    catch ($error) {
        return $error;
    };

    return undef;
}

sub _stderr ($code) {
    my $errors = q{};
    open my $capture, '>', \$errors or BAIL_OUT('capture stderr');
    my $status;
    {
        local *STDERR = $capture;
        $status = $code->();
    }
    close $capture or BAIL_OUT('close stderr');

    return ( $status, $errors );
}

1;
