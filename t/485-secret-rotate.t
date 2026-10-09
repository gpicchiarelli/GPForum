# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(decode_json);
use Mojo::File    qw(path);
use Test::More;

use lib 'lib';

use GPForum::Command::Secret;
use GPForum::Command::Support::ServiceEnvironment;
use GPForum::OS;

our $VERSION = '0.001';

const my $EXIT_FAILURE     => 1;
const my $EXIT_USAGE       => 2;
const my $SECRET_FILE_MODE => oct '640';
const my $MODE_BITS        => oct '7777';
const my $WORLD_READABLE   => oct '644';

# The assertions about a file it cannot write, which root always can.
const my $UNWRITABLE_TESTS => 5;

# What the generator below appends, so a secret it makes is as long as
# production asks of one.
const my $LONG => q{-} . ( 'x' x 32 );

# C3: `gpforum secret rotate session|metrics` writes a new secret into the
# environment file and keeps the one in use among those still accepted, so
# nobody is signed out and no scraper refused; --finish drops the old ones.

my $directory = tempdir( CLEANUP => 1 );
my $counter   = 0;
my $generated = 0;

subtest 'a template left as copied gets its first secret' => sub {
    my $file = _template();
    my $run  = _secret( $file, 'rotate', 'session' );
    is( $run->{status}, 0, 'rotate session succeeds' );
    my %written = _read($file);
    is( $written{GPFORUM_SESSION_SECRET},
        "new-1$LONG", 'the empty secret is filled' );
    ok(
        !exists $written{GPFORUM_SESSION_SECRETS},
        'and nothing is kept, there being nothing before it'
    );
    like( $run->{output}, qr/A [ ] new [ ] session [ ] secret [ ] is [ ] in/msx,
        'it says so' );
    like( $run->{output}, qr/^Next: [ ] /msx, 'and what to do next' );
    unlike( $run->{output}, qr/^Then:/msx,
        'and no --finish, there being nothing to finish' );
    unlike( $run->{output}, qr/new-1/msx, 'without printing the secret' );
    unlike( $run->{output}, qr/^!/msx,    'and no warning on a closed file' );
    is( ( stat $file )[2] & $MODE_BITS,
        $SECRET_FILE_MODE, 'the file keeps its mode' );
};

subtest 'a second rotation keeps the one before, then --finish drops it' =>
  sub {
    my $file = _template();
    _secret( $file, 'rotate', 'session' );
    my $again   = _secret( $file, 'rotate', 'session' );
    my %written = _read($file);
    is( $written{GPFORUM_SESSION_SECRET}, "new-3$LONG", 'a new secret' );
    is( $written{GPFORUM_SESSION_SECRETS},
        "new-2$LONG", 'and the one before still accepted' );
    like( $again->{output}, qr/stays [ ] in [ ] GPFORUM_SESSION_SECRETS/msx,
        'it says so' );
    like(
        $again->{output},
        qr/^Then: [ ] in [ ] 30 [ ] days/msx,
        'and when to finish'
    );

    _secret( $file, 'rotate', 'session' );
    is( { _read($file) }->{GPFORUM_SESSION_SECRETS},
        "new-3$LONG,new-2$LONG", 'a third keeps both, newest first' );

    my $finished = _secret( $file, 'rotate', 'session', '--finish' );
    is( $finished->{status}, 0, '--finish succeeds' );
    ok( !exists { _read($file) }->{GPFORUM_SESSION_SECRETS},
        'and the previous ones are gone' );
    is( { _read($file) }->{GPFORUM_SESSION_SECRET},
        "new-4$LONG", 'the one in use stays' );

    my $nothing = _secret( $file, 'rotate', 'session', '--finish' );
    is( $nothing->{status}, 0, 'finishing again is no failure' );
    like(
        $nothing->{output},
        qr/nothing [ ] to [ ] finish/msx,
        'there is just nothing to drop'
    );
  };

subtest 'the metrics token rotates the same way, beside the rest' => sub {
    my $file = _template();
    _secret( $file, 'rotate', 'metrics' );
    my $before = path($file)->slurp;
    _secret( $file, 'rotate', 'metrics' );
    my %written = _read($file);
    like(
        $written{GPFORUM_METRICS_TOKEN},
        qr/\A new-\d+ \Q$LONG\E \z/msx,
        'a new token'
    );
    ok( defined $written{GPFORUM_METRICS_TOKENS}, 'and the old one kept' );
    is( $written{GPFORUM_ENV}, 'production', 'every other line as it was' );
    my @lines = split /\n/msx, path($file)->slurp;
    my ($token) =
      grep { $lines[$_] =~ /\A GPFORUM_METRICS_TOKEN=/msx } 0 .. $#lines;
    my ($tokens) =
      grep { $lines[$_] =~ /\A GPFORUM_METRICS_TOKENS=/msx } 0 .. $#lines;
    is( $tokens, $token + 1, 'the kept ones on the line after the one in use' );
    is(
        scalar( split /\n/msx, $before ) + 1,
        scalar @lines,
        'one line added, none lost'
    );
};

subtest 'a secret the service refused is replaced, not kept' => sub {
    my %refused = (
        'the development default' => 'gpforum-development-secret-change-me',
        'a secret too short for production' => 'tooshort',
    );
    for my $case ( sort keys %refused ) {
        my $file = _template();
        path($file)
          ->spew( path($file)->slurp =~
s/^GPFORUM_SESSION_SECRET=$/GPFORUM_SESSION_SECRET=$refused{$case}/rmsx
          );
        my $run     = _secret( $file, 'rotate', 'session' );
        my %written = _read($file);
        is( $run->{status}, 0, "$case: rotate succeeds" );
        ok( !exists $written{GPFORUM_SESSION_SECRETS},
            "$case: is not kept, or the next start would refuse the list" );
        unlike(
            $run->{output},
            qr/nobody [ ] is [ ] signed [ ] out/msx,
            "$case: nobody was signed in with it"
        );
        unlike( $run->{output}, qr/^Then:/msx,
            "$case: and there is nothing to finish" );
    }

    my $file = _template();
    path($file)
      ->spew( path($file)->slurp =~
          s/^GPFORUM_ENV=production$/GPFORUM_ENV=development/rmsx =~
          s/^GPFORUM_SESSION_SECRET=$/GPFORUM_SESSION_SECRET=tooshort/rmsx );
    _secret( $file, 'rotate', 'session' );
    is( { _read($file) }->{GPFORUM_SESSION_SECRETS},
        'tooshort', 'a short one development started with is kept' );
};

subtest 'a file every account can read is said, with the chmod' => sub {
    my $file = _template();
    chmod $WORLD_READABLE, $file or croak "chmod: $ERRNO";
    my $run = _secret( $file, 'rotate', 'session' );
    is( $run->{status}, 0, 'the secret is still written' );
    like(
        $run->{output},
qr/^! [ ] Every [ ] account [ ] on [ ] this [ ] host [ ] can [ ] read/msx,
        'but the open file is said'
    );
    like(
        $run->{output},
        qr/: [ ] chmod [ ] 0640 [ ] \Q$file\E$/msx,
        'with the command that closes it'
    );
    is( ( stat $file )[2] & $MODE_BITS,
        $WORLD_READABLE, 'leaving the mode to the operator' );
};

subtest '--dry-run writes nothing, --json prints no secret' => sub {
    my $file   = _template();
    my $before = path($file)->slurp;
    my $dry    = _secret( $file, 'rotate', 'session', '--dry-run' );
    is( $dry->{status},     0,       '--dry-run succeeds' );
    is( path($file)->slurp, $before, 'and leaves the file as it was' );
    like( $dry->{output}, qr/\A Would [ ] write/msx,
        'saying what it would do' );

    my $json     = _secret( $file, 'rotate', 'metrics', '--json' );
    my $document = decode_json( $json->{output} );
    is( $document->{status}, 'ok',      'the document says ok' );
    is( $document->{kind},   'metrics', 'and which secret' );
    is_deeply( $document->{changed}, ['GPFORUM_METRICS_TOKEN'],
        'and which variables changed' );
    unlike( $json->{output}, qr/new-\d/msx, 'but not their values' );
};

subtest 'what it cannot do, it says' => sub {
    my $none = GPForum::Command::Secret->new(
        file                => undef,
        service_environment =>
          GPForum::Command::Support::ServiceEnvironment->new(
            os => GPForum::OS->from_name('linux')
          ),
    );
    my $missing = _captured( sub { $none->run( 'rotate', 'session' ) } );
    is( $missing->{status}, $EXIT_FAILURE, 'no file to write is 1' );
    like(
        $missing->{errors},
        qr{make [ ] /etc/gpforum/gpforum[.]env [ ] from}msx,
        'naming the file to make'
    );

    for my $case (
        [ [],         qr/rotate [ ] session, [ ] or [ ] metrics/msx ],
        [ ['rotate'], qr/rotate: [ ] session [ ] or [ ] metrics/msx ],
        [ [ 'rotate', 'cookies' ], qr/'cookies' [ ] is [ ] not/msx ],
        [
            [ 'rotate', 'session', '--force' ],
            qr/--force [ ] is [ ] not [ ] an [ ] option/msx
        ],
      )
    {
        my ( $arguments, $reason ) = @{$case};
        my $misuse = _secret( _template(), @{$arguments} );
        is( $misuse->{status}, $EXIT_USAGE,
            "gpforum secret @{$arguments} is misuse" );
        like( $misuse->{errors}, $reason, 'saying what was wrong' );
    }

  SKIP: {
        if ( $EFFECTIVE_USER_ID == 0 ) {
            skip 'root writes everywhere', $UNWRITABLE_TESTS;
        }
        my $locked_directory = tempdir( CLEANUP => 1 );
        my $file             = path( $locked_directory, 'gpforum.env' );
        $file->spew("GPFORUM_SESSION_SECRET=\n");
        chmod oct '500', $locked_directory or croak "chmod: $ERRNO";
        my $refused = _secret( "$file", 'rotate', 'session' );
        chmod oct '700', $locked_directory or croak "chmod: $ERRNO";
        is( $refused->{status}, $EXIT_FAILURE, 'a file it cannot write is 1' );
        like(
            $refused->{errors},
            qr/Cannot [ ] write .* run [ ] it [ ] as [ ] root/msx,
            'saying to run it as root'
        );
        like(
            $refused->{errors},
            qr/[(] Permission [ ] denied [)]/msx,
            q{with the system's reason}
        );
        unlike( $refused->{errors}, qr/XXXX|tempfile/msx,
            q{not File::Temp's template} );
        like(
            $refused->{errors},
            qr/: [ ] sudo [ ] gpforum [ ] secret [ ] rotate [ ] session$/msx,
            'and the command that does it'
        );
    }
};

done_testing();

sub _template {
    $counter++;
    my $file = path( $directory, "gpforum-$counter.env" );
    $file->spew( path('deploy/gpforum.env.example')->slurp );
    chmod $SECRET_FILE_MODE, "$file" or croak "chmod: $ERRNO";

    return "$file";
}

sub _secret ( $file, @arguments ) {
    my $command = GPForum::Command::Secret->new(
        file     => $file,
        generate => sub { return 'new-' . ++$generated . $LONG; },
    );

    return _captured( sub { return $command->run(@arguments); } );
}

sub _read ($file) {
    my %assigned;
    for my $line ( split /^/msx, path($file)->slurp ) {
        my $assignment =
          GPForum::Command::Support::ServiceEnvironment->parse_line($line);
        next if !ref $assignment;
        $assigned{ $assignment->[0] } = $assignment->[1];
    }

    return %assigned;
}

sub _captured ($code) {
    my ( $output, $errors ) = ( q{}, q{} );
    my $status;
    {
        open my $stdout, '>', \$output or croak 'capture stdout';
        open my $stderr, '>', \$errors or croak 'capture stderr';
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $status = $code->();
        close $stdout or croak 'close stdout';
        close $stderr or croak 'close stderr';
    }

    return { errors => $errors, output => $output, status => $status };
}

1;
