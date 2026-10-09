# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp       qw(croak);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Mojo::UserAgent;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Benchmark::Process      qw(wait_until_ready);
use GPForum::Benchmark::ReverseProxy qw(resolve_proxy start_proxy);
use GPForum::Command::EvidenceMeta;
use GPForum::Command::HypnotoadBenchmark;
use GPForum::Command::OutboxDispatch;
use GPForum::Command::PerformanceSeed;
use GPForum::Command::ScheduledJobs;
use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Test::BindRecordingDbh;
use GPForum::Test::ReplacedSubs qw(with_replaced_subs);
use GPForum::X::Argument;
use GPForum::X::Config;
use GPForum::X::Unavailable;

our $VERSION = '0.001';

# The command line's own failures are GPForum::X classes (ADR 0118), with the
# text they had as strings: a broken method contract is X::Argument, an input
# or environment the command cannot start from is X::Config, and a process
# that did not start or answer is X::Unavailable. Without croak's location the
# text a command prints is the message alone.

my $directory = tempdir( CLEANUP => 1 );

_test_json_without_status();
_test_evidence_meta_inputs();
_test_reverse_proxy_binary();
_test_forks_that_fail();
_test_server_not_ready();
_test_benchmark_without_database();
_test_seed_on_unmigrated_schema();
_test_command_without_application();

done_testing();

sub _test_json_without_status {
    open my $output, '>', \my $printed or croak 'cannot open buffer';
    my $error =
      _raised( sub { GPForum::Command::Usage->json( $output, { ok => 1 } ) } );
    _is_class(
        $error, 'GPForum::X::Argument',
        'a --json document carries a status',
        'a --json document without a status'
    );
    close $output or croak 'cannot close buffer';
    ok( !length( $printed // q{} ), 'and nothing is printed' );

    return;
}

sub _test_evidence_meta_inputs {
    my $command = GPForum::Command::EvidenceMeta->new;
    my $stamp   = _private( 'GPForum::Command::EvidenceMeta', '_stamp_path' );
    my $missing = "$directory/missing.json";

    _is_class(
        _raised( sub { $command->$stamp( $missing, {} ) } ),
        'GPForum::X::Config',
        "missing evidence file: $missing",
        'a missing evidence file'
    );

    my $array = path("$directory/array.json")->spew('[1]');
    _is_class(
        _raised( sub { $command->$stamp( "$array", {} ) } ),
        'GPForum::X::Config',
        'evidence JSON must be an object',
        'evidence that is not a JSON object'
    );

    my $stderr = q{};
    open my $capture, '>', \$stderr or croak 'cannot capture stderr';
    my $code;
    {
        local *STDERR = $capture;
        $code = $command->run($missing);
    }
    close $capture or croak 'cannot close stderr';
    is( $code, 1, 'the command exits 1' );
    is(
        $stderr,
        "missing evidence file: $missing\n",
        'printing the message without a location'
    );

    return;
}

sub _test_reverse_proxy_binary {
    local $ENV{PATH} = $directory;
    _is_class(
        _raised( sub { resolve_proxy('gpforum-no-such-proxy') } ),
        'GPForum::X::Config',
        'reverse proxy binary not found: gpforum-no-such-proxy',
        'a reverse proxy that is not on PATH'
    );
    _is_class(
        _raised( sub { resolve_proxy('auto') } ),
        'GPForum::X::Config',
        'reverse proxy binary not found; searched nginx and haproxy',
        'no reverse proxy on PATH under auto'
    );

    return;
}

sub _test_forks_that_fail {
    my $no_process = sub { return undef };

    {
        local *GPForum::Benchmark::ReverseProxy::spawn = $no_process;
        _is_class(
            _raised(
                sub {
                    start_proxy( { port => 1 },
                        {}, { kind => 'nginx', binary => 'nginx' } );
                }
            ),
            'GPForum::X::Unavailable',
            'failed to fork reverse proxy benchmark process',
            'a reverse proxy that could not be forked'
        );
    }

    {
        my $start = _private( q{GPForum::Command::HypnotoadBenchmark},
            q{_start_hypnotoad} );
        _is_class(
            _raised(
                sub {
                    with_replaced_subs(
                        q{GPForum::Command::HypnotoadBenchmark},
                        { _spawn => $no_process },
                        sub { $start->( { port => 1 } ) }
                    );
                }
            ),
            'GPForum::X::Unavailable',
            'failed to fork hypnotoad benchmark process',
            'a hypnotoad that could not be forked'
        );
    }

    return;
}

sub _test_server_not_ready {
    my $runtime = {
        ua          => Mojo::UserAgent->new,
        base_url    => 'http://127.0.0.1:1',
        log_file    => "$directory/hypnotoad.log",
        environment => { GPFORUM_STARTUP_TIMEOUT => 0 },
    };
    _is_class(
        _raised( sub { wait_until_ready( $runtime, 'hypnotoad' ) } ),
        'GPForum::X::Unavailable',
        "hypnotoad did not become ready; see $directory/hypnotoad.log",
        'a server that does not become ready'
    );

    return;
}

sub _test_benchmark_without_database {

    # The configuration's own check refuses an empty DSN, so the guard is
    # reached with a configuration built without one.
    local *GPForum::Config::from_environment =
      sub { return GPForum::Config->new( database_dsn => q{} ) };
    my $assert = _private( 'GPForum::Command::HypnotoadBenchmark',
        '_assert_database_available' );
    _is_class(
        _raised( sub { $assert->() } ),
        'GPForum::X::Config',
        'script/bench-hypnotoad requires GPFORUM_DATABASE_DSN',
        'a hypnotoad benchmark without a database'
    );

    return;
}

sub _test_seed_on_unmigrated_schema {
    my $assert =
      _private( 'GPForum::Command::PerformanceSeed', '_assert_migrated' );
    _is_class(
        _raised( sub { $assert->( GPForum::Test::BindRecordingDbh->new ) } ),
        'GPForum::X::Config',
        'database schema is not migrated; '
          . 'run script/gpforum-carton exec bin/gpforum-migrate --apply',
        'a seed on a database without its tables'
    );

    my $migrated = GPForum::Test::BindRecordingDbh->new( row => [1] );
    is( _raised( sub { $assert->($migrated) } ),
        undef, 'and nothing is raised once every table exists' );

    return;
}

# outbox-dispatch and scheduled-jobs build the application only for work that
# runs; one built with neither the application nor its collaborator broke the
# contract, and run reports it as a failure, exit 1, with the message alone.
sub _test_command_without_application {
    my %command = (
        'outbox-dispatch' => [
            GPForum::Command::OutboxDispatch->new,
            sub ($command) { $command->dispatch_once(1) }
        ],
        'scheduled-jobs' => [
            GPForum::Command::ScheduledJobs->new,
            sub ($command) { $command->run_once( {} ) }
        ],
    );

    for my $name ( sort keys %command ) {
        my ( $command, $work ) = @{ $command{$name} };
        _is_class(
            _raised( sub { $work->($command) } ),
            'GPForum::X::Argument',
            'this command was built without an application',
            "$name without an application"
        );

        my $stderr = q{};
        open my $capture, '>', \$stderr or croak 'cannot capture stderr';
        my $code;
        {
            local *STDERR = $capture;
            $code = $command->run('--once');
        }
        close $capture or croak 'cannot close stderr';
        is( $code, 1, "$name exits 1" );
        is(
            $stderr,
            "this command was built without an application\n",
            'printing the message without a location'
        );
    }

    return;
}

sub _is_class ( $error, $class, $message, $label ) {
    ok( $class->caught($error), "$label raises $class" );
    is( "$error", $message, "$label keeps its message" );

    return;
}

sub _raised ($code) {
    try {
        $code->();
    }
    catch ($error) {
        return $error;
    };

    return undef;
}

sub _private ( $class, $name ) {
    return $class->can($name) // croak "no $class->$name";
}

1;
