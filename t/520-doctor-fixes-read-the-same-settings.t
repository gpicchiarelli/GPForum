# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use File::Temp    qw(tempdir);
use IPC::Open3    qw(open3);
use JSON::MaybeXS qw(decode_json encode_json);
use Mojo::File    qw(path);
use Symbol        qw(gensym);
use Test::More;

use lib 'lib';

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Doctor;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::HttpProbe;
use GPForum::Service::Operations::ServiceUnits;
use GPForum::Service::Operations::StagingHostVerify;
use GPForum::Service::Operations::StatusReport;

our $VERSION = '0.001';

# The review of gpforum doctor, run as an operator would: every Fix: it
# prints is a command that acts on the settings doctor read. After `gpforum
# --env-file FILE doctor`, `gpforum migrate` alone would migrate the
# database the host's file names, and `sudo gpforum secret rotate session`
# would write the host's file; a setting the shell holds is not changed by
# editing the file; a port that answers plain HTTP needs the proxy, not a
# certificate; a worker killed in the middle of a batch leaves its claims
# behind, not pending messages; and the evidence staging-host-verify keeps
# carries no password, not even one inside a DSN.

const my $STATUS_SHIFT => 8;
const my $READ_ONLY    => oct '440';
const my $WRITABLE     => oct '640';
const my $HANDSHAKE    => 35;
const my $SECRET       => '0123456789abcdef' x 3;
const my $SERVICE      => 'GPForum::Command::Support::ServiceEnvironment';
const my %PRODUCTION => (
    GPFORUM_ENV             => 'production',
    GPFORUM_MAIL_FROM       => 'forum@forum.gpforum.net',
    GPFORUM_METRICS_TOKEN   => 'metrics-token',
    GPFORUM_PUBLIC_BASE_URL => 'https://forum.gpforum.net',
    GPFORUM_SESSION_SECRET  => $SECRET,
);

my $directory = tempdir( CLEANUP => 1 );

subtest 'a missing secret is written where the settings were read' => sub {
    my $file = path( $directory, 'writable.env' );
    $file->spew("GPFORUM_ENV=production\n");
    $file->chmod($WRITABLE);
    my %lacking = ( %PRODUCTION, GPFORUM_SESSION_SECRET => q{} );

    is_deeply(
        _fixes( _doctor( \%lacking, file => "$file" ) ),
        ['gpforum secret rotate session'],
        'without sudo when this process can write the file'
    );

    $file->chmod($READ_ONLY);
  SKIP: {
        # root writes a read-only file all the same (the FreeBSD CI runs as
        # root), so no sudo is offered there.
        if ( $EFFECTIVE_USER_ID == 0 ) {
            skip 'root can write the read-only file', 1;
        }
        is_deeply(
            _fixes( _doctor( \%lacking, file => "$file" ) ),
            ['sudo gpforum secret rotate session'],
            'with sudo when it cannot'
        );
    }

    like(
        _fixes( _doctor( \%lacking, file => undef ) )->[0],
        qr/openssl [ ] rand/msx,
        'and the command that makes one when no file was read to write'
    );
};

subtest 'a setting the shell holds is fixed in the shell' => sub {
    my $file = path( $directory, 'shell.env' );
    $file->spew("GPFORUM_ENV=production\n");
    my %environment = (
        %PRODUCTION,
        GPFORUM_ENV              => 'prod',
        GPFORUM_WORKER_PROCESSES => '4',
    );

    my $text = _doctor(
        \%environment,
        file     => "$file",
        assigned => [ grep { $_ ne 'GPFORUM_ENV' } keys %environment ],
    )->check->{findings}->human_text;
    like(
        $text,
qr/Fix: [ ] set [ ] GPFORUM_ENV=production [ ] in [ ] your [ ] shell's/msx,
        'the process environment wins over the file, so it is changed there'
    );

    $environment{GPFORUM_ENV} = 'production';
    $text = _doctor(
        \%environment,
        file     => "$file",
        assigned => ['GPFORUM_ENV'],
    )->check->{findings}->human_text;
    like(
        $text,
        qr/Fix: [ ] unset [ ] GPFORUM_WORKER_PROCESSES$/msx,
        'and a retired setting the shell holds is unset there'
    );

    $text = _doctor(
        \%environment,
        file     => "$file",
        assigned => [ keys %environment ],
    )->check->{findings}->human_text;
    like(
        $text,
        qr/remove [ ] the [ ] GPFORUM_WORKER_PROCESSES [ ] line [ ] from/msx,
        'while one the file set is removed from the file'
    );
};

subtest q{the commands offered carry the file this one read} => sub {
    my $file = path( $directory, 'staging copy.env' );
    $file->spew("GPFORUM_ENV=production\nGPFORUM_SESSION_SECRET=\n");
    $file->chmod($WRITABLE);

    my $run = _front_door( '--env-file', "$file", 'doctor' );
    is( $run->{status}, 1, 'doctor fails on the missing secret' );
    like(
        $run->{output},
        qr/Fix: [ ] gpforum [ ] --env-file [ ] '\Q$file\E' [ ] secret [ ]/msx,
        'and offers the rotation of that file, its name quoted for the shell'
    );

    my $json = decode_json(
        _front_door( '--env-file', "$file", 'doctor', '--json' )->{output} );
    my ($secret) =
      grep { $_->{message} =~ /SESSION_SECRET/msx } @{ $json->{findings} };
    like(
        $secret->{fixes}[0],
        qr/\Agpforum [ ] --env-file [ ] '\Q$file\E' [ ] secret/msx,
        'in --json too'
    );
};

subtest 'only gpforum verbs are given the file' => sub {
    my $file = path( $directory, 'verbs.env' );
    $file->spew("GPFORUM_ENV=development\n");
    $SERVICE->new( file => "$file", environment => {} )->load;

    is(
        $SERVICE->as_read(
            join "\n",
            'sudo -u gpforum gpforum migrate',
            'journalctl -u gpforum says why',
            'sudo systemctl restart gpforum gpforum-outbox',
            'see /etc/gpforum/gpforum.env',
            'gpforum budgets --sync'
        ),
        join( "\n",
            "sudo -u gpforum gpforum --env-file $file migrate",
            'journalctl -u gpforum says why',
            'sudo systemctl restart gpforum gpforum-outbox',
            'see /etc/gpforum/gpforum.env',
            "gpforum --env-file $file budgets --sync" ),
        'the service user and the units keep their names'
    );

    no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings) -- the host's own file, without writing one
    local *GPForum::Command::Support::ServiceEnvironment::default_file =
      sub { return "$file" };
    is(
        $SERVICE->as_read('gpforum migrate'),
        'gpforum migrate',
        'and the host file read needs no --env-file'
    );
};

subtest 'an environment file every account can read is said' => sub {
    my $file = path( $directory, 'open.env' );
    $file->spew("GPFORUM_ENV=production\n");
    $file->chmod( oct '644' );
    my $text =
      _doctor( {%PRODUCTION}, file => "$file" )->check->{findings}->human_text;
    like(
        $text,
        qr/^! [ ] settings: [ ] every [ ] account [ ] on [ ] this [ ] host/msx,
        'as a warning'
    );
    like(
        $text,
        qr/Fix: [ ] chmod [ ] 0640 [ ] \Q$file\E$/msx,
        'with the chmod that closes it'
    );

    $file->chmod($WRITABLE);
    unlike(
        _doctor( {%PRODUCTION}, file => "$file" )->check->{findings}
          ->human_text,
        qr/every [ ] account/msx,
        'and not once it is closed'
    );
    $file->chmod( oct '644' );
    unlike(
        _doctor( { %PRODUCTION, GPFORUM_ENV => 'development' },
            file => "$file" )->check->{findings}->human_text,
        qr/every [ ] account/msx,
        'nor in development, where it holds no secret of a forum'
    );
};

subtest 'status does not offer the address it has just tried' => sub {
    my $report = GPForum::Service::Operations::StatusReport->new(
        host => GPForum::Service::Operations::Host->new(
            catalog =>
              GPForum::Service::I18N::CliCatalog->new( language => 'en' ),
            environment => 'production',
            os          => GPForum::OS->from_name('linux'),
        )
    );
    my $tried = 'http://127.0.0.1:8080';
    my $text  = $report->findings(
        { state => 'unreachable', url => $tried, reason => 'refused' } )
      ->{findings}->human_text;
    like(
        $text,
        qr/gpforum [ ] status [ ] --url [ ] http:/msx,
        'it names --url'
    );
    unlike( $text, qr/--url [ ] \Q$tried\E/msx, 'for another address' );
};

subtest 'a module the checks cannot load is a dependency to install' => sub {
    my $hide = path( $directory, 'hide' );
    $hide->make_path;
    path( $hide, 'HideDBIxClass.pm' )->spew(<<'PERL');
package HideDBIxClass;
unshift @INC, sub {
    my ( $hook, $file ) = @_;
    die "Can't locate $file in \@INC (hidden by t/520)\n"
      if $file eq 'DBIx/Class.pm';
    return;
};
1;
PERL
    my $file = path( $directory, 'upgrade.env' );
    $file->spew("GPFORUM_ENV=development\n");

    local $ENV{PERL5OPT} = "-I$hide -MHideDBIxClass";
    my $run = _front_door( '--env-file', "$file", 'doctor', '--upgrade' );
    is( $run->{status}, 1, 'doctor --upgrade fails' );
    like(
        $run->{output},
        qr/^\S+ [ ] dependencies: [ ] not [ ] installed [ ]/msx,
        'it says a module is not installed'
    );
    like(
        $run->{output},
        qr/: [ ] DBIx::Class$/msx,
        q{naming it, not with Perl's error}
    );
    like(
        $run->{output},
        qr/Fix: [ ] make [ ] install-deps-postgres$/msx,
        'with the command that installs it'
    );
    unlike(
        $run->{errors},
        qr/Compilation [ ] failed/msx,
        'and no stack of requires'
    );
};

subtest q{the template's example address is corrected, not put in the DNS} =>
  sub {
    my $unknown = sub {
        return { error => 'Could not resolve host', kind => 'unresolved' };
    };
    my $text = _doctor(
        { %PRODUCTION, GPFORUM_PUBLIC_BASE_URL => 'https://forum.example.com' },
        os      => 'linux',
        address => $unknown,
    )->check->{findings}->human_text;
    like(
        $text,
        qr/Fix: [ ] correct [ ] GPFORUM_PUBLIC_BASE_URL [ ] in [ ] /msx,
        'the example address is the setting to correct'
    );
    unlike( $text, qr/in [ ] the [ ] DNS/msx, 'not a name to point anywhere' );

    like(
        _doctor( {%PRODUCTION}, os => 'linux', address => $unknown )
          ->check->{findings}->human_text,
        qr/point [ ] forum[.]gpforum[.]net [ ] at [ ] this [ ] host/msx,
        q{while a real name is one the DNS does not know yet}
    );
  };

subtest 'a port that answers plain HTTP is the proxy, not a certificate' =>
  sub {
    my $curl = path( $directory, 'curl' );
    $curl->spew(<<"SH");
#!/bin/sh
cat > /dev/null
echo 'curl: ($HANDSHAKE) LibreSSL: tlsv1 alert protocol version' >&2
exit $HANDSHAKE
SH
    $curl->chmod( oct '755' );
    my $answer = GPForum::Service::Operations::HttpProbe->new(
        curl    => "$curl",
        can_tls => 0
    )->get('https://forum.gpforum.net/health/live');
    is( $answer->{kind}, 'handshake', 'curl 35 is a failed handshake' );

    my $text = _doctor(
        {%PRODUCTION},
        os      => 'linux',
        address => sub { return $answer },
    )->check->{findings}->human_text;
    like( $text,
        qr/address: [ ] no [ ] TLS [ ] handshake [ ] with [ ] https:/msx,
        'said as such' );
    ok(
        index( $text, "Fix: put GPForum's nginx site in place:\n" ) >= 0
          && index( $text,
            'gpforum service print nginx --to /etc/nginx/sites-enabled' ) >= 0,
        'with the proxy to put in place, as gpforum service print writes it'
    );
    unlike(
        $text,
        qr/Fix: [ ] sudo [ ] certbot/msx,
        'not a certificate first: the one it takes is a step of the site'
    );
  };

subtest 'the archived evidence keeps no password inside a value' => sub {
    my $file = path( $directory, 'evidence.env' );
    $file->spew(<<"ENV");
GPFORUM_SESSION_SECRET=$SECRET
GPFORUM_DATABASE_DSN=dbi:Pg:dbname=gpforum
GPFORUM_DATABASE_USER=gpforum
GPFORUM_METRICS_TOKEN=$SECRET
GPFORUM_PUBLIC_BASE_URL=https://staging.gpforum.net
GPFORUM_MAIL_FROM=forum\@staging.gpforum.net
GPFORUM_GLIFISTORE_URL=http://cache:hunter2-secret\@cache.internal:7379/x
ENV
    my $evidence =
      GPForum::Service::Operations::StagingHostVerify->new->run(
        { env_file => "$file" } )->{env_file};
    is_deeply(
        [ map { $_->{variable} } @{ $evidence->{problems} } ],
        ['GPFORUM_GLIFISTORE_URL'],
        'the address in the wrong form is the problem'
    );
    unlike( encode_json($evidence), qr/hunter2/msx,
        'and its password is not in the evidence' );
};

done_testing();

sub _doctor ( $environment, %given ) {
    my $os      = delete $given{os};
    my $address = delete $given{address};
    my $catalog = GPForum::Service::I18N::CliCatalog->new( language => 'en' );

    return GPForum::Service::Operations::Doctor->new(
        catalog     => $catalog,
        environment => $environment,
        file        => '/etc/gpforum/gpforum.env',
        probes      => {
            address   => $address // sub { return { code => 200 } },
            antivirus =>
              sub { return { status => 'disabled', engine => 'none' } },
            database => sub { die "no database here\n" },
            mail     => sub {
                return {
                    status => 'pass',
                    probe  => { action => 'log_transport' }
                };
            },
            preflight => sub {
                return {
                    checks => [],
                    os     => {
                        name          => 'linux',
                        event_backend => 'epoll',
                        cpu_count     => 1
                    },
                    resources => { file_descriptor_limit => 65_536 },
                    runtime   => { web_processes         => 2 },
                };
            },
        },
        units => _no_units(),
        ( $os ? ( os => GPForum::OS->from_name($os) ) : () ),
        %given,
    );
}

# A host without service files to compare: the units are t/494's.
sub _no_units {
    return GPForum::Service::Operations::ServiceUnits->new(
        directory => $directory,
        systemctl => undef,
    );
}

sub _fixes ($doctor) {
    my $findings = $doctor->check->{findings}->document;
    my ($secret) = grep { $_->{message} =~ /SESSION_SECRET/msx } @{$findings};

    return $secret->{fixes};
}

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

1;
