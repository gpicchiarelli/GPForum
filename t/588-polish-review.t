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
use Mojolicious;
use Symbol qw(gensym);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::CLI::FrontDoor::Carton ();
use GPForum::Command::MailCheck;
use GPForum::Command::ScheduledJobs;
use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Config::Report;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::DatabaseFailure;
use GPForum::Test::JobsSummary;
use GPForum::Test::SendmailFound;
use GPForum::X::Config;

our $VERSION = '0.001';

const my $EXIT_SHIFT => 8;
const my $PASSWORD   => 'hunter2';

# The review of iteration 3's polish stream, run as an operator runs it:
# - `gpforum --env-file F partitions` on a database never migrated said
#   "apply the migrations with gpforum migrate", which, typed as offered,
#   migrated the database the host's file names, not F's;
# - doctor redacted a password inside a refused setting, but every other verb
#   and the service's own start quoted it whole in the settings report;
# - `mail-check --send --to ADDRESS`, typed as doctor offers it, went to
#   sendmail with ADDRESS as a local user and said a message was sent;
# - `perl gpforum-migrate`, typed in bin/, died with "gpforum-migrate: not
#   found" when it ran itself again under the checkout's dependencies;
# - `gpforum --env-file F service print rc` ended with `sudo service gpforum
#   --env-file F start`: the FreeBSD service's name read as gpforum, and its
#   start as the verb;
# - bin/gpforum-scheduled-jobs, which the systemd timer runs, died with
#   "Can't locate object method gp_scheduled_jobs": the application it built
#   was gone before the controller asked it for the jobs;
# - in Italian, `gpforum scheduled-jobs` gave the jobs' reasons in English,
#   "non eseguito (scanning is off)", and "sessioni scadute: 12 rimossi".

local $ENV{LC_ALL} = 'en_US.UTF-8';
my $file = path( tempdir( CLEANUP => 1 ), 'staging.env' );
$file->spew("GPFORUM_ENV=staging\n");
GPForum::Command::Support::ServiceEnvironment->new(
    file        => "$file",
    environment => {},
)->load;

subtest 'a failure offers its gpforum command on the file this run read' =>
  \&_failure_reads_the_file;
subtest 'no settings report quotes a password a value carries' =>
  \&_no_password_quoted;
subtest 'mail-check sends only to an address' => \&_mail_check_needs_an_address;
subtest 'an entrypoint typed bare in bin/ runs itself again' =>
  \&_bare_entrypoint_runs;
subtest 'the FreeBSD service is not read as a gpforum verb' =>
  \&_service_is_not_a_verb;
subtest 'scheduled-jobs keeps the application it builds' =>
  \&_jobs_keep_their_application;
subtest 'scheduled-jobs says why in the operator\'s language' =>
  \&_jobs_say_why;

done_testing();

sub _failure_reads_the_file {
    my $sentence = GPForum::Service::Operations::DatabaseFailure->new(
        environment_file => "$file" )->not_migrated('audit_log');
    my $said = _stderr(
        sub {
            is( GPForum::Command::Usage->failure($sentence),
                1, 'it is a failure' );
        }
    );
    ok(
        index( $said, "the migrations with gpforum --env-file $file migrate," )
          >= 0,
        'the migration it offers reads the same file'
    ) or diag $said;

    return;
}

sub _no_password_quoted {
    my $error;
    try {
        GPForum::Config->from_environment(
            {
                GPFORUM_ENV             => 'development',
                GPFORUM_PUBLIC_BASE_URL => "ftp://admin:$PASSWORD\@forum.test",
            }
        );
    }
    catch ($caught) {
        $error = GPForum::X::Config->caught($caught);
    };
    ok( $error, 'an address with no http:// is refused' );

    for my $report (
        [ 'the error itself' => $error->message ],
        [
            'the front door' =>
              GPForum::Command::Support::Words->new->config_report(
                $error->problems, "$file"
              )
        ],
        [
            'a DSN quoted in any sentence' => GPForum::Config::Report->sentence(
                {
                    key      => 'config.url',
                    variable => 'GPFORUM_MINION_PG_URL',
                    value    => "dbi:Pg:dbname=minion;password='$PASSWORD x'",
                }
            )
        ],
      )
    {
        my ( $name, $text ) = @{$report};
        unlike( $text, qr/$PASSWORD/msx, "$name: no password" );
        like( $text, qr/\[redacted\]/msx, "$name: shown as redacted" );
    }

    return;
}

sub _mail_check_needs_an_address {
    for my $language (qw(en it)) {
        local $ENV{LC_ALL} = $language eq 'it' ? 'it_IT.UTF-8' : 'en_US.UTF-8';
        my $command =
          GPForum::Command::MailCheck->new(
            check => GPForum::Test::SendmailFound->new );
        my $status;
        my $said = _stderr(
            sub { $status = $command->run(qw(--send --to ADDRESS --human)) } );
        is( $status, 2, "$language: --to ADDRESS, as offered, is misuse" );
        my $expected =
          $language eq 'it'
          ? "'ADDRESS' non \N{LATIN SMALL LETTER E WITH GRAVE} un indirizzo email."
          : q{'ADDRESS' is not an email address.};
        ok( index( $said, $expected ) == 0, "$language: which it says first" )
          or diag $said;
    }

    return;
}

sub _bare_entrypoint_runs {
    is(
        GPForum::CLI::FrontDoor::Carton->program('gpforum-migrate'),
        './gpforum-migrate',
        'a bare name is a file here'
    );
    is( GPForum::CLI::FrontDoor::Carton->program('bin/gpforum-migrate'),
        'bin/gpforum-migrate', 'a path stays as typed' );

    if ( !-d 'local/lib/perl5' ) {
        note 'no local/ here to run the entrypoints under';
        return;
    }
    my $ran =
      _run( 'bin', $EXECUTABLE_NAME, 'gpforum-outbox-dispatch', '--help' );
    is( $ran->{status}, 0, 'perl gpforum-outbox-dispatch, in bin/, runs' )
      or diag $ran->{errors};
    like(
        $ran->{output},
        qr/\A Usage: [ ] bin\/gpforum-outbox-dispatch [ ]/msx,
        'and prints its usage'
    );

    return;
}

sub _service_is_not_a_verb {
    is(
        GPForum::Command::Support::ServiceEnvironment->as_read(
            'sudo service gpforum start, then gpforum status'),
        "sudo service gpforum start, then gpforum --env-file $file status",
        'service gpforum start stays as service(8) takes it'
    );

    return;
}

sub _jobs_keep_their_application {
    my $status;
    my $output = _written(
        sub ($handle) {
            $status = GPForum::Command::ScheduledJobs->new(
                app => sub {
                    my $app = Mojolicious->new;
                    $app->helper(
                        gp_scheduled_jobs => sub {
                            return GPForum::Test::JobsSummary->new;
                        }
                    );
                    return $app;
                },
                output => $handle,
            )->run('--once');
        }
    );
    is( $status, 0, 'built for the run, the application runs the jobs' );
    like( $output, qr/\A scheduled_jobs [ ] ok=1/msx, 'and says so' );

    return;
}

sub _jobs_say_why {
    my $summary = {
        ok                  => 0,
        sessions            => { deleted => 12 },
        attachment_scans    => { error   => 'antivirus unavailable', ok => 0 },
        attachment_backfill =>
          { ok => 1, scanned => 0, skipped => 'scanning is off' },
    };
    my $italian = _jobs( 'it', $summary );
    for my $english ( 'scanning is off', 'antivirus unavailable' ) {
        unlike( $italian, qr/$english/msx, "no '$english' in Italian" );
    }
    for my $said (
"non eseguito (la scansione \N{LATIN SMALL LETTER E WITH GRAVE} spenta)",
        'in attesa di scansione: antivirus non disponibile',
        'sessioni scadute: 12 elementi rimossi',
      )
    {
        ok( index( $italian, $said ) >= 0, "it says: $said" )
          or diag $italian;
    }
    ok(
        index(
            _jobs( 'en', $summary ),
            "antivirus unavailable\n    Fix: gpforum --env-file $file"
              . " antivirus-check says why\n"
        ) >= 0,
        'and a scanner that does not answer is sent to antivirus-check,'
          . ' on the file this run read'
    ) or diag _jobs( 'en', $summary );

    return;
}

sub _jobs ( $language, $summary ) {
    return _written(
        sub ($handle) {
            return GPForum::Command::ScheduledJobs->new(
                human => 1,
                jobs  => GPForum::Test::JobsSummary->new( summary => $summary ),
                output => $handle,
                words  => GPForum::Command::Support::Words->new(
                    catalog => GPForum::Service::I18N::CliCatalog->new(
                        language => $language
                    )
                ),
            )->run('--once');
        }
    );
}

# What a command wrote to the handle it was given, decoded.
sub _written ($code) {
    my $output = q{};
    open my $handle, '>', \$output or croak 'capture';
    $code->($handle);
    close $handle or croak 'close capture';
    utf8::decode($output);

    return $output;
}

sub _stderr ($code) {
    my $said = q{};
    {
        open my $stderr, '>', \$said or croak 'capture stderr';
        local *STDERR = $stderr;
        $code->();
        close $stderr or croak 'close stderr';
    }
    utf8::decode($said);

    return $said;
}

# A program run in a directory with none of the test's library paths, as an
# operator's shell runs it.
sub _run ( $directory, @command ) {
    local %ENV = %ENV;
    delete @ENV{qw(PERL5LIB PERL5OPT)};

    my $errors = gensym;
    my $pid =
      open3( my $input, my $stdout, $errors, 'sh', '-c',
        'cd "$1" && shift && exec "$@"',
        'sh', $directory, @command );
    close $input or croak "close: $OS_ERROR";
    my $output = do { local $INPUT_RECORD_SEPARATOR = undef; <$stdout> };
    my $said   = do { local $INPUT_RECORD_SEPARATOR = undef; <$errors> };
    waitpid $pid, 0;

    return {
        errors => $said   // q{},
        output => $output // q{},
        status => $CHILD_ERROR >> $EXIT_SHIFT,
    };
}

1;
