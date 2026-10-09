# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use Cwd        qw(getcwd);
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use IPC::Open3 qw(open3);
use Mojo::File qw(path);
use Mojo::Server;
use Mojo::Util qw(decode);
use Symbol     qw(gensym);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::CLI::FrontDoor::Launcher;
use GPForum::Command::Support::Verbs;

our $VERSION = '0.001';

const my $EXIT_FAILURE => 1;
const my $EXIT_USAGE   => 2;
const my $EX_CONFIG    => 78;
const my $STATUS_SHIFT => 8;

# B1, B2 and B6: one front door, `gpforum VERB`, with help of its own, the
# old names still answering, and the service's environment file read.

my $root = getcwd();

subtest 'gpforum help groups the verbs as an operator works' => sub {
    my $help = _in_process( { LC_ALL => 'en_US.UTF-8' } );
    is( $help->{status}, 0, 'gpforum alone is help, and succeeds' );
    like(
        $help->{output},
        qr/\A Usage: [ ] gpforum [ ] \[--env-file [ ] FILE\] [ ] COMMAND/msx,
        'opening with how to call it'
    );
    my @groups = $help->{output} =~ /^(Set [ ] up|Run|Check|Maintain)$/gmsx;
    is_deeply(
        \@groups,
        [ 'Set up', 'Run', 'Check', 'Maintain' ],
        'in four groups, in the order of the work'
    );
    like(
        $help->{output},
        qr/^ [ ]{2} migrate [ ]+ Bring [ ] the [ ] database/msx,
        'each verb with one line'
    );
    unlike(
        $help->{output},
        qr/lite-app|--mode|cpanify|APPLICATION/msx,
        q{and none of Mojolicious's generic banner}
    );
    unlike(
        $help->{output},
        qr/^ [ ]{2} (?:daemon|staging-drill) \b/msx,
        'nor the framework and the drills'
    );
    like(
        $help->{output},
        qr/^Settings [ ] (?:are [ ] read|come)/msx,
        'and says where the settings come from'
    );

    my $missing = _in_process(
        { LC_ALL => 'en_US.UTF-8' }, '--env-file',
        '/nonexistent/gpforum.env',  'help'
    );
    like(
        $missing->{output},
        qr{^There [ ] is [ ] no [ ] /nonexistent/gpforum[.]env:}msx,
        'and that a file named with --env-file is not there'
    );
    unlike(
        $missing->{output},
        qr/^Settings [ ] are [ ] read/msx,
        'rather than that the settings are read from it'
    );

    my $all = _in_process( { LC_ALL => 'en_US.UTF-8' }, 'help', '--all' );
    like(
        $all->{output},
        qr/^ [ ]{2} staging-drill [ ]/msx,
        'help --all adds the drills'
    );
    like(
        $all->{output},
        qr/^ [ ]{2} daemon [ ]/msx,
        q{and Mojolicious's own commands}
    );

    my $italian = _in_process( { LC_ALL => 'it_IT.UTF-8' } );
    like(
        decode( 'UTF-8', $italian->{output} ),
        qr/^Installazione$ .* ^Manutenzione$/msx,
        'in Italian too'
    );
};

subtest 'a verb explains itself as the operator typed it' => sub {
    my $migrate = _in_process( { LC_ALL => 'en_US.UTF-8' }, 'help', 'migrate' );
    like(
        $migrate->{output},
        qr/\A Usage: [ ] gpforum [ ] migrate/msx,
        'gpforum help migrate is its usage'
    );
    my $partitions =
      _in_process( { LC_ALL => 'en_US.UTF-8' }, 'help', 'partitions' );
    like(
        $partitions->{output},
        qr/gpforum [ ] partitions/msx,
        'a verb whose command had another name is shown by the verb'
    );
    unlike(
        $partitions->{output},
        qr{bin/gpforum-partition-maintenance}msx,
        'not by the old entrypoint'
    );

    _each_verb_explains_itself();
};

subtest 'misuse says what was wrong' => sub {
    my $unknown = _in_process( { LC_ALL => 'en_US.UTF-8' }, 'migarte' );
    is( $unknown->{status}, $EXIT_USAGE, 'an unknown verb is 2' );
    like( $unknown->{errors},
        qr/'migarte' [ ] is [ ] not [ ] a [ ] gpforum [ ] command/msx,
        'naming it' );
    like(
        $unknown->{errors},
        qr/Did [ ] you [ ] mean [ ] gpforum [ ] migrate[?]/msx,
        'and the verb it is closest to'
    );

    my $option =
      _in_process( { LC_ALL => 'en_US.UTF-8' }, '--apply', 'migrate' );
    is( $option->{status}, $EXIT_USAGE, 'an option before the verb is 2' );
    like(
        $option->{errors},
        qr/gpforum [ ] has [ ] no [ ] option [ ] --apply/msx,
        'saying a command takes its options after its name'
    );

    my $missing = _in_process( { LC_ALL => 'en_US.UTF-8' }, '--env-file' );
    like(
        $missing->{errors},
        qr/--env-file [ ] needs [ ] a [ ] value/msx,
        '--env-file without a file says so'
    );
};

subtest 'old names answer, and every entrypoint has its verb' => sub {
    my $launcher = GPForum::CLI::FrontDoor::Launcher->new;
    for my $case (
        [qw(outbox outbox-dispatch outbox_dispatch)],
        [qw(partitions partition-maintenance)],
        [qw(budgets query-budget query_budget)],
        [qw(admin admin-bootstrap)],
      )
    {
        my ( $verb, @old ) = @{$case};
        my $class   = $launcher->resolve($verb)->{class};
        my $command = _command_of($class);
        for my $name (@old) {
            is( _command_of( $launcher->resolve($name)->{class} ),
                $command, "gpforum $name runs what gpforum $verb runs" );
        }
    }
    ok( $launcher->resolve('daemon')->{needs_application},
        q{Mojolicious's daemon still runs} );
    ok( $launcher->resolve('start')->{needs_application},
        'and start runs the application too' );
    for my $worker (qw(outbox outbox-dispatch scheduled-jobs)) {
        ok(
            $launcher->resolve($worker)->{needs_application},
            "gpforum $worker builds the application its work comes from"
        );
    }
    for my $nonsense ( 'Migrate', '../migrate', 'generate' ) {
        is( $launcher->resolve($nonsense), undef, "'$nonsense' is no verb" );
    }

    for my $entrypoint ( grep { $_->basename ne 'gpforum' }
        path('bin')->list->each )
    {
        my $name = $entrypoint->basename;
        my $typed =
          GPForum::Command::Support::Verbs->typed_for_entrypoint($name);
        ok( defined $typed, "bin/$name has a verb" );
        next if !defined $typed;
        my ( undef, $verb ) = split q{ }, $typed;
        my $resolved = $launcher->resolve($verb);
        my ($runs) = $entrypoint->slurp =~ /(GPForum::Command::\w+)->/msx;
        is( _command_of( $resolved && $resolved->{class} ),
            $runs, "$typed runs what bin/$name runs" );
    }

    is(
        GPForum::Command::Support::Verbs->as_typed(
'run script/gpforum-carton exec perl -Ilib bin/gpforum-migrate --apply'
        ),
        'run gpforum migrate',
        'a documented incantation reads as the front door, which applies'
    );
    is(
        GPForum::Command::Support::Verbs->as_typed(
'bin/gpforum-migrate --plan, then bin/gpforum-partition-maintenance --apply'
        ),
        'gpforum migrate --plan, then gpforum partitions --apply',
        'an option the verb does not imply stays'
    );
    is(
        GPForum::Command::Support::Verbs->as_typed(
            'ExecStart=/opt/gpforum/bin/gpforum-outbox-dispatch --loop'),
        'ExecStart=/opt/gpforum/bin/gpforum-outbox-dispatch --loop',
        'while a path under another directory is left alone'
    );
};

subtest 'the front door reads the service environment file' => sub {
    my $directory = tempdir( CLEANUP => 1 );
    my $file      = path( $directory, 'gpforum.env' );
    $file->spew("# a test\nGPFORUM_ENV=prod\n");

    my $wrong = _started( {}, '--env-file', "$file", 'routes' );
    is( $wrong->{status}, $EX_CONFIG, 'a wrong setting in it is EX_CONFIG' );
    like(
        $wrong->{errors},
        qr/GPFORUM_ENV [ ] must [ ] be [ ] one [ ] of/msx,
        'reported as every command reports it'
    );
    like(
        $wrong->{errors},
        qr/^Set [ ] these [ ] in [ ] \Q$file\E,/msx,
        'ending with the file it read'
    );

    my $help = _started( {}, '--env-file', "$file", 'outbox', '--help' );
    is( $help->{status}, 0,
        'a verb that runs the application explains itself without settings' );
    like(
        $help->{output},
        qr/\A Usage: [ ] gpforum [ ] outbox [ ]/msx,
        'by the name typed'
    );

    my $kept =
      _started( { GPFORUM_ENV => 'test' }, '--env-file', "$file", 'routes' );
    is( $kept->{status}, 0, 'what the shell sets comes first' );

    my $after = _started( {}, 'routes', '--env-file', "$file" );
    is( $after->{status}, $EX_CONFIG,
        'an --env-file after the verb is read too' );
    like(
        $after->{errors},
        qr/GPFORUM_ENV [ ] must [ ] be [ ] one [ ] of/msx,
        'as the one before it'
    );
    my $bare = _started( {}, 'routes', '--env-file' );
    is( $bare->{status}, $EXIT_USAGE, 'and one without a file is misuse' );

    my $absent = _started( {}, '--env-file', "$directory/none.env", 'routes' );
    is( $absent->{status}, $EX_CONFIG, 'a file that is not there is 78' );
    like( $absent->{errors}, qr/There [ ] is [ ] no [ ] \Q$directory\E/msx,
        'saying so' );
};

subtest 'start says an address it cannot listen on, with what to do' =>
  \&_assert_listen_failures;

subtest 'it runs from anywhere, without local/ on @INC' => sub {
    if ( !-d "$root/local/lib/perl5" ) {
        plan skip_all => 'the dependencies are not in local/';
    }
    my $elsewhere = tempdir( CLEANUP => 1 );
    chdir $elsewhere or croak "chdir: $ERRNO";
    my $help = _started( { PERL5LIB => undef }, 'help' );
    chdir $root or croak "chdir: $ERRNO";
    is( $help->{status}, 0, 'gpforum help succeeds from another directory' );
    like( $help->{output}, qr/^Maintain$/msx, 'and prints its help' );
};

subtest 'Hypnotoad loads it as the application' => sub {
    local $ENV{GPFORUM_ENV} = 'test';
    my $application;
    try {
        $application = Mojo::Server->new->load_app("$root/bin/gpforum");
    }
    catch ($error) {
        diag $error;
    };
    isa_ok( $application, 'GPForum',
        'bin/gpforum returns the application, as load_app needs' );
};

done_testing();

# gpforum VERB --help, for every verb there is, names what was typed.
sub _each_verb_explains_itself {
    my $launcher = GPForum::CLI::FrontDoor::Launcher->new;
    for my $verb ( map { $_->{verb} }
        @{ GPForum::Command::Support::Verbs->verbs } )
    {
        next if !$launcher->resolve($verb);
        my $help = _in_process( { LC_ALL => 'en_US.UTF-8' }, $verb, '--help' );
        is( $help->{status}, 0, "gpforum $verb --help succeeds" );
        like(
            $help->{output},
            qr/\A Usage: [ ] gpforum [ ] \Q$verb\E \b/msx,
            'naming the verb typed'
        );
        unlike( $help->{output}, qr{bin/gpforum-}msx,
            'and no entrypoint from before the front door' );
    }

    return;
}

# The launcher run in this process, with the environment given, capturing
# what it prints.
sub _assert_listen_failures {
    my $held = IO::Socket::INET->new(
        Listen    => 1,
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
    ) or croak "listen: $ERRNO";
    my $address = 'http://127.0.0.1:' . $held->sockport;
    my $next    = 'http://127.0.0.1:' . ( $held->sockport + 1 );

    my $busy = _started( {}, 'start', '--foreground', '--listen', $address );
    is( $busy->{status}, $EXIT_FAILURE,
        'a port another process holds is 1, not the error number' );
    ok( index( $busy->{errors}, "Something else listens on $address (" ) == 0,
        'said in a sentence' );
    ok(
        index( $busy->{errors},
            ": gpforum start --foreground --listen $next\n" ) > 0,
        'with the command that listens on the next port'
    );
    unlike(
        $busy->{errors},
        qr/[ ] line [ ] \d+/msx,
        'and no Perl file or line'
    );

    my $bogus = _started( {}, 'start', '--foreground', '--listen', 'bogus' );
    is( $bogus->{status}, $EXIT_USAGE, 'an address that is no URL is misuse' );
    like( $bogus->{errors}, qr/\A --listen [ ] does [ ] not [ ] take/msx,
        'saying which' );
    close $held or croak "close: $ERRNO";

    return;
}

sub _in_process ( $environment, @arguments ) {
    my ( $output, $errors ) = ( q{}, q{} );
    my $status;
    {
        local @ENV{ keys %{$environment} } = values %{$environment};
        open my $stdout, '>', \$output or croak 'capture stdout';
        open my $stderr, '>', \$errors or croak 'capture stderr';
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $status = GPForum::CLI::FrontDoor::Launcher->new->run(@arguments);
        close $stdout or croak 'close stdout';
        close $stderr or croak 'close stderr';
    }
    chdir $root or croak "chdir: $ERRNO";

    return { errors => $errors, output => $output, status => $status };
}

# bin/gpforum started as an operator starts it, with the given variables
# added (undef removes one) and GPFORUM_* otherwise cleared.
sub _started ( $environment, @arguments ) {
    my %clean = map { $_ => $ENV{$_} }
      grep { !/\A GPFORUM_/msx } keys %ENV;
    my %wanted = ( %clean, LC_ALL => 'en_US.UTF-8', %{$environment} );
    delete @wanted{ grep { !defined $wanted{$_} } keys %wanted };
    my ( $pid, $output, $errors );
    {
        local %ENV = %wanted;
        $errors = gensym;
        $pid    = open3( my $input, $output, $errors, $EXECUTABLE_NAME,
            "$root/bin/gpforum", @arguments );
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

# The GPForum::Command class an adapter runs, read from its source.
sub _command_of ($class) {
    return undef if !defined $class;

    my $file = $class =~ s{::}{/}grmsx;
    my ($command) =
      path("$root/lib/$file.pm")->slurp =~ /(GPForum::Command::\w+)->/msx;

    return $command;
}

1;
