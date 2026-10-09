# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use Cwd        qw(getcwd);
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Bootstrap::Config;
use GPForum::CLI::FrontDoor::Launcher;
use GPForum::Command::MailCheck;
use GPForum::Config;
use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Doctor;
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::MailCheck;
use GPForum::X::Config;

our $VERSION = '0.001';

const my $EX_CONFIG     => 78;
const my $SECRET_LENGTH => 40;

# The service's start stops when mail leaves by smtp with TLS on and this
# Perl cannot load IO::Socket::SSL (Bootstrap::Config). The settings review
# found the operator's other ways in did not say so: gpforum doctor answered
# "settings: production" and gpforum mail-check "Nothing to fix" for the
# settings the start refused, mail-check --send failed with Net::SMTP's own
# "To use SSL please install IO::Socket::SSL ... at Net/SMTP.pm line 268.",
# and gpforum start or outbox --env-file FILE ended by sending the operator to
# the template instead of FILE. Each now answers as the start does. doctor
# said nothing of an old name the start warns of, and mail-check --send's
# closing note printed its catalog key, mailcheck.check_inbox.
#
# This Perl's answer is replaced: the test holds on a host with the module
# and on one without.

local %ENV = %ENV;
delete @ENV{ grep { /\A GPFORUM_/msx } keys %ENV };
local $ENV{LC_ALL} = 'en_US.UTF-8';

my $root       = getcwd();
my %production = (
    GPFORUM_ENV             => 'production',
    GPFORUM_SESSION_SECRET  => 's' x $SECRET_LENGTH,
    GPFORUM_METRICS_TOKEN   => 'm' x $SECRET_LENGTH,
    GPFORUM_PUBLIC_BASE_URL => 'https://forum.gpforum.test',
    GPFORUM_MAIL_FROM       => 'forum@gpforum.test',
    GPFORUM_ANTIVIRUS       => 'none',
    GPFORUM_MAIL_TRANSPORT  => 'smtp',
    GPFORUM_SMTP_HOST       => 'smtp.gpforum.test',
);
const my $SENTENCE =>
  qr/\A GPFORUM_SMTP_TLS=starttls [ ] encrypts [ ] mail [ ] through/msx;

subtest 'the configuration says when TLS cannot be spoken' => sub {
    my $config  = GPForum::Config->from_environment( {%production} );
    my $problem = $config->smtp_tls_problem(0);
    is( $problem->{key},      'config.smtp_tls_module', 'smtp, starttls' );
    is( $problem->{variable}, 'GPFORUM_SMTP_TLS',       'under its name' );
    is( $config->smtp_tls_problem(1), undef, 'none where the module loads' );
    is_deeply( GPForum::Bootstrap::Config->tls_problem( $config, 0 ),
        $problem, 'the start-up asks the configuration' );

    for my $fine (
        [ GPFORUM_SMTP_TLS       => 'off' ],
        [ GPFORUM_MAIL_TRANSPORT => 'sendmail' ],
      )
    {
        my $other = GPForum::Config->from_environment(
            { %production, $fine->[0] => $fine->[1] } );
        is( $other->smtp_tls_problem(0),
            undef, "none with $fine->[0]=$fine->[1]" );
    }

    my $refused = eval { $config->assert_smtp_tls(0); 1 } ? undef : $EVAL_ERROR;
    ok( GPForum::X::Config->caught($refused), 'assert_smtp_tls throws' );
    is( $refused->problems->[0]{key},
        'config.smtp_tls_module', 'with the problem' );
    is( $config->assert_smtp_tls(1), $config, 'and returns it otherwise' );

    require Net::SMTP;
    is(
        GPForum::Config->smtp_can_tls,
        Net::SMTP->can_ssl ? 1 : 0,
        q{smtp_can_tls is Net::SMTP's own answer}
    );
};

subtest 'doctor refuses the settings the start refuses' => sub {
    my ( $findings, $config ) = _doctor_settings( {%production}, 0 );
    is( $config, undef, 'the settings cannot be used' );
    my ($finding) = @{ $findings->document };
    is( $finding->{status}, 'fail', 'a failure' );
    like( $finding->{message}, $SENTENCE, 'in the start-up sentence' );
    is_deeply( $finding->{fixes}, [],
        'whose two fixes it names itself, with no "correct" line' );

    ( $findings, $config ) = _doctor_settings( {%production}, 1 );
    ok( $config, 'where the module loads, the settings are fine' );
    is( $findings->document->[0]{status}, 'ok', 'and said so' );
};

subtest 'doctor warns of an old name, as the start does' => sub {
    my %old = ( %production, GPFORUM_SMTP_SSL => 'off' );
    my ( $findings, $config ) =
      _doctor_settings( \%old, 1, assigned => ['GPFORUM_SMTP_SSL'] );
    ok( $config, 'an old name does not stop anything' );
    my ($renamed) =
      grep { $_->{status} eq 'degraded' } @{ $findings->document };
    is(
        $renamed->{message},
        'GPFORUM_SMTP_SSL is now called GPFORUM_SMTP_TLS; write'
          . ' GPFORUM_SMTP_TLS=off in the environment file in its place.',
        'the line to write instead'
    );
    is_deeply(
        $renamed->{fixes},
        ['remove the GPFORUM_SMTP_SSL line from /etc/gpforum/gpforum.env'],
        'and the old line to remove from the file'
    );

    ( $findings, $config ) = _doctor_settings( \%old, 1, assigned => [] );
    ($renamed) =
      grep { $_->{status} eq 'degraded' } @{ $findings->document };
    is_deeply(
        $renamed->{fixes},
        ['unset GPFORUM_SMTP_SSL'],
        'or the shell, when it set the old name'
    );
};

subtest 'mail-check stops as the start does, before the relay' => sub {
    no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings) -- this Perl's answer, replaced for the test
    local *GPForum::Config::smtp_can_tls = sub { return 0 };
    local @ENV{ keys %production } = values %production;

    my ( $status, $output, $errors ) =
      _captured( sub { GPForum::Command::MailCheck->new->run('--json') } );
    is( $status, $EX_CONFIG, 'EX_CONFIG, as every setting it cannot use' );
    like(
        $errors,
        qr/^ [ ]{2} GPFORUM_SMTP_TLS=starttls [ ] encrypts/msx,
        'the sentence, on standard error'
    );
    like( $output, qr/"status":"fail"/msx, 'and evidence that failed' );
};

subtest 'gpforum start and outbox name the file they read' => sub {
    no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings) -- this Perl's answer, replaced for the test
    local *GPForum::Config::smtp_can_tls = sub { return 0 };
    my $file = path( tempdir( CLEANUP => 1 ), 'gpforum.env' );
    $file->spew( join q{},
        map { "$_=$production{$_}\n" } sort keys %production );

    for my $verb (qw(start outbox)) {
        local %ENV = %ENV;
        my ( $status, undef, $errors ) = _captured(
            sub {
                GPForum::CLI::FrontDoor::Launcher->new->run( '--env-file',
                    "$file", $verb );
            }
        );
        chdir $root or croak "chdir: $ERRNO";
        is( $status, $EX_CONFIG, "$verb: EX_CONFIG" );
        like(
            $errors,
            qr/GPFORUM_SMTP_TLS=starttls [ ] encrypts/msx,
            "$verb: the TLS sentence"
        );
        like(
            $errors,
qr/^Set [ ] these [ ] in [ ] \Q$file\E, [ ] then [ ] try [ ] again[.]$/msx,
            "$verb: and the file it read, not the template"
        );
    }
};

subtest 'mail-check --send says to look in the inbox, in words' => sub {
    my $check = GPForum::Service::Operations::MailCheck->new(
        config => GPForum::Config->new( mail_transport => 'test' ) );
    my $text = $check->human_text(
        {
            status => 'pass',
            config => { mail_from => 'forum@gpforum.test' },
            probe  => { action    => 'send', to => 'me@gpforum.test' },
        }
    );
    like( $text, qr/Check [ ] that [ ] it [ ] arrived/msx, 'the note' );
    unlike( $text, qr/mailcheck[.]check_inbox/msx, 'not its key' );

    my $evidence = GPForum::Service::Operations::MailCheck->new(
        config => GPForum::Config->from_environment(
            {
                %production,
                GPFORUM_MAIL_TRANSPORT => 'log',
                GPFORUM_ENV            => 'development'
            }
        )
    )->run( { mode => 'dry_run' } );
    is( $evidence->{config}{smtp}{tls},
        'starttls', 'the evidence gives GPFORUM_SMTP_TLS' );
    is( $evidence->{config}{smtp}{ssl}, 1, 'and the old ssl, for old readers' );
};

done_testing();

sub _doctor_settings ( $environment, $can_tls, %options ) {
    my $catalog = GPForum::Service::I18N::CliCatalog->new;
    my $doctor  = GPForum::Service::Operations::Doctor->new(
        catalog     => $catalog,
        environment => $environment,
        file        => '/etc/gpforum/gpforum.env',
        assigned    => $options{assigned} // [ sort keys %{$environment} ],
        os          => GPForum::OS->from_name('linux'),
        probes      => { tls => sub { return $can_tls } },
    );
    my $findings =
      GPForum::Service::Operations::Findings->new( catalog => $catalog );
    my $config = $doctor->settings( $environment, $findings );

    return ( $findings, $config );
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

    return ( $status, $output, $errors );
}

1;
