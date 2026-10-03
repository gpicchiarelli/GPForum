# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use File::Temp    qw(tempdir);
use IPC::Open3    qw(open3);
use JSON::MaybeXS qw(decode_json);
use Mojo::File    qw(path);
use Symbol        qw(gensym);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::AntivirusCheck;
use GPForum::Command::DeadLetterCheck;
use GPForum::Command::EvidenceValidate;
use GPForum::Command::MailCheck;
use GPForum::Command::MailLifecycleCheck;
use GPForum::Command::PartitionMaintenance;
use GPForum::Command::StagingDrill;
use GPForum::Command::StagingDrillAttachments;
use GPForum::Command::StagingHostVerify;
use GPForum::Command::StressLoad;
use GPForum::Schema;
use GPForum::Service::Operations::EvidenceValidate;
use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Test::FailingEvidenceCheck;
use GPForum::Test::RefusedSchema;

our $VERSION = '0.001';

const my $EXIT_OK      => 0;
const my $EXIT_FAILURE => 1;
const my $EXIT_USAGE   => 2;

# system() and waitpid keep the exit status in the high byte.
const my $EXIT_STATUS_SHIFT => 8;

# What FailingEvidenceCheck raises, as an operator should read it: the
# password= the DSN carried redacted, and no code location.
const my $REDACTED_REASON =>
  q{DBI connect('dbname=gpforum;host=127.0.0.1;password=[redacted] failed: }
  . 'Connection refused';

# And RefusedSchema's, through partition-maintenance: the lifecycle names
# what it could not do, and the refusal follows on one line.
const my $CANNOT_CONNECT =>
  'partition lifecycle: cannot connect to the database: ';
const my $REFUSED_REASON => $CANNOT_CONNECT
  . 'DBIx::Class::Storage::DBI::catch {...} (): DBI Connection failed: '
  . q{DBI connect('dbname=gpforum;host=127.0.0.1;port=1;password=[redacted] }
  . 'failed: connection to server at "127.0.0.1", port 1 failed: Connection'
  . ' refused Is the server running on that host and accepting TCP/IP'
  . ' connections?';

# Admin CLI, a leftover of the --json review. An error the check itself
# raised -- not misuse, not a failed check it reported -- was rethrown by
# these commands with die. An uncaught exception exits 255, or with whatever
# $! held: 2, the misuse code, after a failed file lookup. Now it is the
# failure every other command reports (Command::Usage): 1, the reason on
# stderr, redacted, and under --json -- the evidence commands' default -- a
# document saying fail.
#
# Each evidence command: the class, the attribute its check is injected by,
# the identity its evidence carries, the type evidence-validate classifies
# that by, and the arguments a run needs.
const my %EVIDENCE => (
    'dead-letter-check' => [
        'DeadLetterCheck', 'check',
        { check => 'dead_letter_check', mode => 'simulate' },
        'dead_letter_check',
    ],
    'evidence-validate' => [
        'EvidenceValidate',               'validate',
        { check => 'evidence_validate' }, 'evidence_validate',
        'archive.json',
    ],
    'mail-check' => [
        'MailCheck',                                     'check',
        { check => 'mail_delivery', mode => 'dry_run' }, 'mail_delivery',
    ],
    'mail-lifecycle-check' => [
        'MailLifecycleCheck', 'check',
        { check => 'mail_lifecycle_check', mode => 'simulate' },
        'mail_lifecycle_check',
    ],
    'staging-drill' => [
        'StagingDrill',               'drill',
        { check => 'staging_drill' }, 'staging_drill',
    ],
    'staging-drill-attachments' => [
        'StagingDrillAttachments',
        'attachment_drill',
        {
            check => 'staging_ops_extensions',
            drill => 'staging_ops_extensions',
        },
        'staging_ops_extensions',
        '--attachments-only',
    ],
    'staging-host-verify' => [
        'StagingHostVerify',                'verify',
        { check => 'staging_host_verify' }, 'staging_host_verify',
    ],
    'stress-load' => [
        'StressLoad',              'load',
        { mode => 'stress-load' }, 'stress_load',
        '--base-url',              'http://127.0.0.1:9',
    ],
);

my $archive = tempdir( CLEANUP => 1 );

for my $name ( sort keys %EVIDENCE ) {
    _assert_evidence_failure($name);
}
_assert_antivirus_failure();
_assert_stress_load_aim();
_assert_partition_maintenance_unreachable();

done_testing();

sub _assert_evidence_failure {
    my ($name) = @_;
    my ( $class, $attribute, $identity, $type, @arguments ) =
      @{ $EVIDENCE{$name} };

    my $json = _run( _failing( $class, $attribute ), @arguments );
    is( $json->{status}, $EXIT_FAILURE, "$name whose check dies is 1" );
    _assert_reason( $json->{errors}, $name );
    my $document = _document( $json, $name );
    is( $document->{status}, 'fail',           'and its evidence says fail' );
    is( $document->{error},  $REDACTED_REASON, 'with the reason, redacted' );
    is_deeply( { map { $_ => $document->{$_} } keys %{$identity} },
        $identity, 'naming the check, as its passing evidence does' );
    _assert_archivable( $name, $json->{output}, $type );

    my $human = _run( _failing( $class, $attribute ), @arguments, '--human' );
    is( $human->{status}, $EXIT_FAILURE,
        "$name --human whose check dies is 1" );
    _assert_reason( $human->{errors}, "$name --human" );
    is( $human->{output}, q{}, 'and prints nothing on stdout' );

    # The process, not only the method: die exited with $!, here 2.
    my $process = _spawn( $class, $attribute, @arguments );
    is( $process->{status}, $EXIT_FAILURE,
        "$name in its own process, as bin/ runs it, exits 1" );
    is( _document( $process, "$name in its own process" )->{status},
        'fail', 'having printed its evidence' );

    # Misuse kept its usage exit, without the " at bin/... line N." croak
    # left on it.
    my $misuse = _run( _failing( $class, $attribute ), '--bogus' );
    is( $misuse->{status}, $EXIT_USAGE, "$name misused is 2" );
    like(
        $misuse->{errors},
        qr/\A Unknown [ ] option: [ ] --bogus \n Usage: [ ] bin\//msx,
        'with the usage on stderr'
    );
    unlike(
        $misuse->{errors},
        qr/[ ] line [ ] \d+/msx,
        'without the code location'
    );
    is( $misuse->{output}, q{}, 'and nothing on stdout' );

    return;
}

# antivirus-check reports a misconfiguration as evidence itself; an error it
# raises instead was rethrown too. Its evidence has its own shape.
sub _assert_antivirus_failure {
    my $json = _run( _failing( 'AntivirusCheck', 'check' ), '--json' );
    is( $json->{status}, $EXIT_FAILURE,
        'antivirus-check whose check dies is 1' );
    _assert_reason( $json->{errors}, 'antivirus-check' );
    my $document = _document( $json, 'antivirus-check' );
    is( $document->{status}, 'fail',           'and its evidence says fail' );
    is( $document->{error},  $REDACTED_REASON, 'with the reason, redacted' );
    is( $document->{engine}, 'unknown',        'in the shape of its evidence' );
    is_deeply( $document->{problems}, [], 'with no problem it found' );

    my $human = _run( _failing( 'AntivirusCheck', 'check' ) );
    is( $human->{status}, $EXIT_FAILURE,
        'antivirus-check whose check dies is 1 by default too' );
    _assert_reason( $human->{errors}, 'antivirus-check' );
    is( $human->{output}, q{}, 'and prints nothing on stdout' );

    my $process = _spawn( 'AntivirusCheck', 'check', '--json' );
    is( $process->{status}, $EXIT_FAILURE,
        'antivirus-check in its own process exits 1' );

    return;
}

# stress-load's usage says --base-url is required unless --dry-run; the
# service refusing a run without it was an uncaught exception, 255.
sub _assert_stress_load_aim {
    delete local $ENV{GPFORUM_STRESS_BASE_URL};

    my $unaimed = _run( _failing( 'StressLoad', 'load' ) );
    is( $unaimed->{status}, $EXIT_USAGE, 'stress-load with no target is 2' );
    like(
        $unaimed->{errors},
qr/\A --base-url [ ] is [ ] required [ ] unless [ ] --dry-run \n Usage: /msx,
        'saying what is missing, then the usage'
    );
    is( $unaimed->{output}, q{}, 'and nothing on stdout' );
    is( _run( _failing( 'StressLoad', 'load' ), '--help' )->{status},
        $EXIT_OK, 'asking for help needs no target' );
    is( _run( _failing( 'StressLoad', 'load' ), '--dry-run' )->{status},
        $EXIT_FAILURE, 'nor does a dry run: it reaches the check' );

    local $ENV{GPFORUM_STRESS_BASE_URL} = 'http://127.0.0.1:9';
    is( _run( _failing( 'StressLoad', 'load' ) )->{status},
        $EXIT_FAILURE, 'nor a run GPFORUM_STRESS_BASE_URL aims' );

    return;
}

# The lifecycle swallowed the connection error, so this said only "a database
# handle is required". The reason comes through, redacted.
sub _assert_partition_maintenance_unreachable {
    my $refused = sub {
        return GPForum::Command::PartitionMaintenance->new(
            lifecycle => GPForum::Service::Operations::PartitionLifecycle->new(
                schema => GPForum::Test::RefusedSchema->new
            )
        );
    };
    my $lines = _run( $refused->(), '--plan' );
    is( $lines->{status}, $EXIT_FAILURE,
        'partition-maintenance against a refusing database is 1' );
    like( $lines->{errors}, qr/\A [^\n]+ \n \z/msx, 'the reason on one line' );
    my ($reason) = $lines->{errors} =~ /\A ([^\n]*) \n/msx;
    is( $reason, $REFUSED_REASON, 'saying why: the connection refused' );
    unlike( $lines->{errors}, qr/hunter2/msx,          'without the password' );
    unlike( $lines->{errors}, qr/[ ] line [ ] \d+/msx, 'or a code location' );

    my $json = _run( $refused->(), '--plan', '--json' );
    is( $json->{status}, $EXIT_FAILURE, 'and under --json' );
    my $document = _document( $json, 'partition-maintenance refused' );
    is( $document->{status}, 'fail',          'whose document says fail' );
    is( $document->{error},  $REFUSED_REASON, 'and why' );

    # The real thing: DBIx::Class connecting to a port nothing listens on.
    my $real = _run(
        GPForum::Command::PartitionMaintenance->new(
            lifecycle => GPForum::Service::Operations::PartitionLifecycle->new(
                schema => GPForum::Schema->connect(
                    'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=1;'
                      . 'password=hunter2',
                    'gpforum',
                    q{},
                    { PrintError => 0, RaiseError => 1 },
                )
            )
        ),
        '--plan'
    );
    is( $real->{status}, $EXIT_FAILURE,
        'partition-maintenance against a closed port is 1' );
    like( $real->{errors}, qr/\A\Q$CANNOT_CONNECT\E/msx,
        'saying it cannot connect' );
    like( $real->{errors}, qr/DBI[ ]connect/msx, 'and what DBI said' );
    like( $real->{errors}, qr/password=[[]redacted[]]/msx, 'redacted' );
    unlike( $real->{errors}, qr/hunter2/msx, 'the password gone' );
    unlike(
        $real->{errors},
        qr/[ ] line [ ] \d+/msx,
        'and without the locations DBI and DBIx::Class put on it'
    );

    return;
}

sub _assert_reason {
    my ( $errors, $label ) = @_;

    like( $errors, qr/\A [^\n]+ \n \z/msx, "$label says why on one line" );
    my ($reason) = $errors =~ /\A ([^\n]*) \n/msx;
    is( $reason, $REDACTED_REASON,
        'the password redacted, the code location gone' );

    return;
}

# The document a failed run printed is evidence an operator can archive: what
# evidence-validate --strict asks of an archived file, it has.
sub _assert_archivable {
    my ( $name, $printed, $type ) = @_;

    my $file = path( $archive, "$name.json" );
    $file->spew($printed);
    my $report = GPForum::Service::Operations::EvidenceValidate->new->run(
        { paths => ["$file"], strict => 1 } );
    my $checked = $report->{files}[0];
    is( $checked->{detected_type}, $type,  'evidence-validate knows its kind' );
    is( $checked->{status},        'pass', 'and accepts it for the archive' )
      or diag explain $checked->{findings};

    return;
}

sub _failing {
    my ( $class, $attribute ) = @_;

    return
      "GPForum::Command::$class"
      ->new( $attribute => GPForum::Test::FailingEvidenceCheck->new );
}

sub _document {
    my ( $result, $label ) = @_;

    my $output = $result->{output};
    like( $output, qr/\A [^\n]+ \n \z/msx, "$label prints one line" );
    my $document = eval { decode_json($output) };
    ok( ref $document eq 'HASH', "$label is a JSON object" )
      or diag $EVAL_ERROR;

    return $document || {};
}

sub _run {
    my ( $command, @arguments ) = @_;

    my ( $output, $errors ) = ( q{}, q{} );
    my $status;
    {
        open my $stdout, '>', \$output or croak 'capture stdout';
        open my $stderr, '>', \$errors or croak 'capture stderr';
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $status = eval { $command->run(@arguments) };
        if ( !defined $status ) {
            $errors .= "died: $EVAL_ERROR";
        }
        close $stdout or croak 'close stdout';
        close $stderr or croak 'close stderr';
    }

    return { errors => $errors, output => $output, status => $status };
}

# The command as bin/ runs it, `exit Command->new->run(@ARGV)`, in its own
# process, so the exit status is the one an operator's shell sees.
sub _spawn {
    my ( $class, $attribute, @arguments ) = @_;

    my $code = join q{ }, "use GPForum::Command::$class;",
      'use GPForum::Test::FailingEvidenceCheck;',
      "exit GPForum::Command::$class->new( $attribute =>",
      'GPForum::Test::FailingEvidenceCheck->new )->run(@ARGV);';
    my $errors = gensym;
    my $pid    = open3(
        my $input, my $output, $errors, $EXECUTABLE_NAME,
        '-Ilib',   '-It/lib',  '-e',    $code,
        q{--},     @arguments
    );
    close $input or croak "close child input: $ERRNO";
    my $printed = do { local $INPUT_RECORD_SEPARATOR = undef; <$output> };
    my $said    = do { local $INPUT_RECORD_SEPARATOR = undef; <$errors> };
    waitpid $pid, 0;

    return {
        errors => $said    // q{},
        output => $printed // q{},
        status => $CHILD_ERROR >> $EXIT_STATUS_SHIFT,
    };
}

1;
