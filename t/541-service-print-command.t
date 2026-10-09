# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use Cwd           qw(getcwd);
use English       qw(-no_match_vars);
use File::Temp    qw(tempdir);
use IPC::Open3    qw(open3);
use JSON::MaybeXS qw(decode_json);
use Mojo::File    qw(path);
use Mojo::Util    qw(decode);
use Symbol        qw(gensym);
use Test::More;

use lib 'lib';

use GPForum::Command::Service;
use GPForum::Command::Support::Words;
use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceFiles;

our $VERSION = '0.001';

const my $EXIT_OK      => 0;
const my $EXIT_FAILURE => 1;
const my $EXIT_USAGE   => 2;
const my $STATUS_SHIFT => 8;
const my $READ_MODE    => oct '640';

# `gpforum service print`, audit item C2: what the operator types and
# reads. The files go to standard output, alone, so a pipe into sudo tee
# writes the file; the steps that put them in place go to standard error,
# or after the files written with --to. It installs nothing.

my $root = getcwd();
my $SITE = 'https://forum.walk.org';

subtest 'one file prints alone, its steps beside it' => sub {
    my $run = _run( { GPFORUM_PUBLIC_BASE_URL => $SITE }, qw(print nginx) );
    is( $run->{status}, $EXIT_OK, 'printed' );
    like(
        $run->{output},
        qr/\A upstream [ ] gpforum_backend/msx,
        'standard output is the site and nothing before it'
    );
    is(
        $run->{errors},
        join( "\n",
            'Next: put it in place:',
            '  sudo certbot certonly --nginx -d forum.walk.org',
            '  sudo gpforum service print nginx --to /etc/nginx/sites-enabled',
            '  sudo nginx -t && sudo systemctl reload nginx',
            q{} ),
        'standard error says how to put it in place'
    );
};

subtest q{without a target, this host's service manager, every file headed} =>
  sub {
    my $run    = _run( {}, 'print' );
    my @headed = $run->{output} =~ m{^==> [ ] (\S+) [ ] <==$}gmsx;
    is_deeply(
        \@headed,
        [
            map { "/etc/systemd/system/$_" }
              qw(gpforum.service gpforum-outbox.service
              gpforum-scheduled-jobs.service gpforum-scheduled-jobs.timer
              gpforum-partition-maintenance.service
              gpforum-partition-maintenance.timer)
        ],
        'the six units, each under the path it goes to'
    );
    is(
        $run->{errors},
        join( "\n",
            'Next: put them in place and start them:',
            '  sudo gpforum service print systemd --to /etc/systemd/system',
            '  sudo systemctl daemon-reload && sudo systemctl enable --now'
              . ' gpforum gpforum-outbox gpforum-scheduled-jobs.timer'
              . ' gpforum-partition-maintenance.timer',
            q{} ),
        'then printed where systemd reads them, and started: two lines'
    );
  };

subtest '--to writes them, where the command was typed, to read first' => sub {
    my $typed_in = tempdir( CLEANUP => 1 );
    my $run = _run( {}, qw(print rc --to units/), { directory => $typed_in } );
    is( $run->{status}, $EXIT_OK, 'written' ) or diag $run->{errors};
    my $units = path( $typed_in, 'units' );
    is_deeply(
        [ sort map { $_->basename } $units->list->each ],
        [qw(gpforum gpforum_jobs gpforum_outbox)],
        'in a directory of their own, under the one typed in'
    );
    ok( -x $units->child('gpforum'),       'the rc scripts executable' );
    ok( !-x $units->child('gpforum_jobs'), 'the crontab not' );
    is(
        decode( 'UTF-8', $run->{output} ),
        join( "\n",
            "\N{CHECK MARK} 3 files for rc are in units: gpforum,"
              . ' gpforum_outbox, gpforum_jobs.',
            'Next: read them, then put them in place and start them:',
            '  sudo cp units/gpforum units/gpforum_outbox /usr/local/etc/rc.d/',
            '  sudo mkdir -p /usr/local/etc/cron.d',
            '  sudo cp units/gpforum_jobs /usr/local/etc/cron.d/',
            '  sudo sysrc gpforum_enable=YES && sudo service gpforum start',
            '  sudo sysrc gpforum_outbox_enable=YES'
              . ' && sudo service gpforum_outbox start',
            q{} ),
        'said in one line, then the copies from it, as typed'
    );

    my $again = _run( {}, qw(print rc --to units), { directory => $typed_in } );
    is( $again->{status}, $EXIT_OK, 'written again over its own files' );

    my $other =
      _run( {}, qw(print nginx --to units), { directory => $typed_in } );
    is( $other->{status}, $EXIT_FAILURE, 'but not beside files of another' );
    _starts(
        $other->{errors},
        q{units holds files that are not nginx's}
          . ' (gpforum, gpforum_jobs, gpforum_outbox)',
        'which would be copied with them'
    );
    ok( !-e $units->child('gpforum.conf'), 'and nothing is written' );

    path( $typed_in, 'plain' )->spew('x');
    is(
        _run( {}, qw(print nginx --to plain), { directory => $typed_in } )
          ->{status},
        $EXIT_FAILURE,
        'nor into a file'
    );
};

subtest 'misuse says what was wrong, with the usage' => sub {
    my %wrong = (
        'service'               => 'Say what to print:',
        'service status'        => 'Say what to print:',
        'service print upstart' => q{'upstart' is not one of systemd's files}
          . ' (gpforum.service, gpforum-outbox.service,'
          . ' gpforum-scheduled-jobs.service, gpforum-scheduled-jobs.timer,'
          . ' gpforum-partition-maintenance.service,'
          . ' gpforum-partition-maintenance.timer), nor something gpforum'
          . ' service prints (systemd, rc, launchd, nginx, caddy).',
        'service print nginx gpforum.service' =>
          q{'gpforum.service' is not one of nginx's files (gpforum.conf)},
        'service print --to'      => '--to needs a value.',
        'service print --install' => '--install is not an option',
    );
    for my $line ( sort keys %wrong ) {
        my ( undef, @arguments ) = split q{ }, $line;
        my $run = _run( {}, @arguments );
        is( $run->{status}, $EXIT_USAGE, "gpforum $line: 2" );
        _starts( $run->{errors}, $wrong{$line}, 'and why' );
        _has(
            $run->{errors},
            "\nUsage: gpforum service print",
            'with the usage'
        );
    }

    my $nowhere = _run( {}, 'print', { os => 'unknown' } );
    is( $nowhere->{status}, $EXIT_USAGE, 'a host GPForum ships no files for' );
    _has(
        $nowhere->{errors},
        'name one, systemd, rc, launchd, nginx, caddy.',
        'is asked to name one'
    );
};

subtest 'in Italian' => sub {
    my $run    = _run( {}, qw(print caddy), { language => 'it' } );
    my $errors = decode( 'UTF-8', $run->{errors} );
    _starts(
        $errors,
        "! GPFORUM_PUBLIC_BASE_URL \N{LATIN SMALL LETTER E WITH GRAVE}"
          . q{ http://127.0.0.1:3000, non l'indirizzo},
        'the note'
    );
    _has(
        $errors,
        "\nProssimo passo: mettilo al suo posto:\n",
        'and the next step'
    );
};

subtest '--json: one document, the files and the steps' => sub {
    my $run =
      _run( { GPFORUM_PUBLIC_BASE_URL => $SITE }, qw(print nginx --json) );
    my $document = decode_json( $run->{output} );
    is( $document->{status}, 'ok',    'ok' );
    is( $document->{target}, 'nginx', 'for nginx' );
    is(
        $document->{files}[0]{path},
        '/etc/nginx/sites-enabled/gpforum',
        'with where the file goes'
    );
    _has(
        $document->{files}[0]{text},
        'server_name forum.walk.org;',
        'its text'
    );
    _starts(
        $document->{next}[1],
        'sudo gpforum service print nginx',
        'and the steps'
    );
    is( $run->{errors}, q{}, 'and nothing else' );
};

subtest 'through the front door, from another directory, with --env-file' =>
  sub {
    my $typed_in = tempdir( CLEANUP => 1 );
    my $file     = path( $typed_in, 'forum.env' );
    $file->spew("GPFORUM_PUBLIC_BASE_URL=$SITE\n");
    $file->chmod($READ_MODE);

    my $help = _started( $typed_in, 'help' );
    my ($setup) = $help->{output} =~ /^Set [ ] up\n (.*?) \n\n/msx;
    _has( $setup // q{}, '  service ', 'service is in Set up' );

    my $printed =
      _started( $typed_in, '--env-file', "$file", qw(service print nginx) );
    is( $printed->{status}, $EXIT_OK, 'printed' );
    _has(
        $printed->{output},
        'server_name forum.walk.org;',
        'for the forum the file names'
    );
    _has(
        $printed->{errors},
        "\n  sudo gpforum --env-file $file service print nginx --to ",
        'and the step prints it again from the same file, with sudo for it'
    );

    my $written = _started(
        $typed_in, '--env-file', "$file", qw(service print
          systemd --to units)
    );
    is( $written->{status}, $EXIT_OK, 'written' ) or diag $written->{errors};
    ok(
        -e path( $typed_in, 'units', 'gpforum.service' ),
        'into the directory typed in, not the code directory'
    );
    ok( !-e path( $root, 'units' ), 'which is left alone' );
    _has( path( $typed_in, 'units', 'gpforum-outbox.service' )->slurp,
        "\nEnvironmentFile=$file\n", 'the units read that file' );
  };

done_testing();

# The command run in this process for a Linux host, with the settings given,
# capturing what it prints.
sub _run ( $settings, @arguments ) {
    my $options = ref $arguments[-1] ? pop @arguments : {};
    my $catalog =
      GPForum::Service::I18N::CliCatalog->new( language => $options->{language}
          // 'en' );
    my $host = GPForum::Service::Operations::Host->new(
        catalog     => $catalog,
        environment => 'production',
        os          => GPForum::OS->from_name( $options->{os} // 'linux' ),
    );
    my $command = GPForum::Command::Service->new(
        directory => $options->{directory} // $root,
        files     => GPForum::Service::Operations::ServiceFiles->new(
            environment => $settings,
            host        => $host,
            home        => '/opt/gpforum',
            found       => sub ($program) { return 1 },
            exists      => sub ($file) { return 0 },
        ),
        words => GPForum::Command::Support::Words->new( catalog => $catalog ),
    );

    return _captured(
        sub ( $stdout, $stderr ) {
            $command->output($stdout);
            $command->errors($stderr);
            return $command->run(@arguments);
        }
    );
}

# What a piece of code prints on standard output and standard error, and
# what it returns.
sub _captured ($code) {
    my ( $output, $errors ) = ( q{}, q{} );
    open my $stdout, '>', \$output or croak 'capture stdout';
    open my $stderr, '>', \$errors or croak 'capture stderr';
    my $status = do {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $code->( $stdout, $stderr );
    };
    close $stdout or croak 'close stdout';
    close $stderr or croak 'close stderr';

    return { errors => $errors, output => $output, status => $status };
}

# bin/gpforum started from a directory, as an operator starts it.
sub _started ( $directory, @arguments ) {
    my %clean = map { $_ => $ENV{$_} } grep { !/\A GPFORUM_/msx } keys %ENV;
    my ( $pid, $output, $errors );
    {
        local %ENV = ( %clean, LC_ALL => 'en_US.UTF-8' );
        chdir $directory or croak "chdir: $ERRNO";
        $errors = gensym;
        $pid    = open3( my $input, $output, $errors, $EXECUTABLE_NAME,
            "$root/bin/gpforum", @arguments );
        close $input or croak "close child input: $ERRNO";
        chdir $root  or croak "chdir: $ERRNO";
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

sub _has ( $text, $literal, $name ) {
    return ok( index( $text, $literal ) >= 0, $name ) || diag $text;
}

sub _starts ( $text, $literal, $name ) {
    return ok( index( $text, $literal ) == 0, $name ) || diag $text;
}

1;
