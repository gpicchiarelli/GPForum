# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::OsPreflight;
use GPForum::Config;
use GPForum::OS::Linux;
use GPForum::OS::Preflight;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Test::OSResourceSnapshot;
use GPForum::Test::OSTinyLinux;

our $VERSION = '0.001';

# GPFORUM_WEB_PROCESSES' default when the walkthrough was made.
const my $CONFIGURED_WEB => 4;

# What cap-to-cpu gives Hypnotoad on one CPU: GPFORUM_RUNTIME_MAX_WEB_PER_CPU.
const my $CAPPED_WEB => 2;

# A per-CPU allowance other than the default, to see it carried over.
const my $PER_CPU => 3;

# The walkthrough (docs/ops/evidence/2026-10-07-operator-walkthrough, item 3)
# read that the shipped units could not start on a 1-vCPU VPS: their
# ExecStartPre ran `os-preflight --strict`, which failed on any degraded
# check, and one CPU is always degraded twice -- its recommended worker count
# (1) is below GPFORUM_OS_MIN_RECOMMENDED_WORKERS (2), and the configured 4
# web processes were compared with 1 x 2 although Hypnotoad is given 2.

subtest 'the check counts the web processes Hypnotoad is given' => sub {
    my $runtime = _one_cpu( worker_policy => 'cap-to-cpu' );
    is(
        GPForum::OS::RuntimePolicy->new(
            config  => GPForum::Config->new,
            runtime => $runtime,
        )->hypnotoad_config->{workers},
        $CAPPED_WEB,
        'cap-to-cpu gives Hypnotoad two on one CPU'
    );
    is( $runtime->effective_web_processes,
        $CAPPED_WEB, 'and the runtime says the same number' );
    is( _check( $runtime, 'web_processes' )->{status},
        'ok', 'so the preflight finds nothing oversubscribed' );

    my $configured = _one_cpu( worker_policy => 'configured' );
    is( $configured->effective_web_processes,
        $CONFIGURED_WEB, 'the configured policy gives Hypnotoad all four' );
    is( _check( $configured, 'web_processes' )->{status},
        'degraded', 'and that is still reported as oversubscribed' );
};

subtest 'the policy comes from the configuration' => sub {
    my $runtime = GPForum::Runtime->from_config(
        GPForum::Config->new(
            runtime_worker_policy   => 'configured',
            runtime_max_web_per_cpu => $PER_CPU,
        )
    );
    is( $runtime->worker_policy,   'configured', 'the worker policy' );
    is( $runtime->max_web_per_cpu, $PER_CPU,     'and the processes per CPU' );
};

subtest 'a degraded host starts, and says why on stderr' => sub {
    my $run =
      _run( _one_cpu( worker_policy => 'cap-to-cpu' ), '--strict', '--json' );
    is( decode_json( $run->{output} )->{status},
        'degraded', 'one CPU is degraded' );
    is( $run->{status}, 0, 'but --strict lets the service start' );
    is_deeply(
        [ split /\n/msx, $run->{errors} ],
        [
            'os-preflight: ! workers: this host carries 1, fewer than'
              . ' GPFORUM_OS_MIN_RECOMMENDED_WORKERS (2)',
            'os-preflight:     Fix: set GPFORUM_OS_MIN_RECOMMENDED_WORKERS=1'
              . q{ in your shell's environment, or give the host more CPUs},
        ],
        'and says each degraded check, and its fix, on stderr for the journal'
    );

    my $quiet = _run( _one_cpu( worker_policy => 'cap-to-cpu' ), '--json' );
    is( $quiet->{status}, 0,   'without --strict the status is the same' );
    is( $quiet->{errors}, q{}, 'and stderr stays quiet, as before' );
};

subtest 'a failed check still stops the start' => sub {
    my $no_cpu = GPForum::Runtime->new(
        web_processes => 1,
        os_profile    => GPForum::OS::Linux->new(
            cpu_detection  => { count => 0, source => 'test' },
            resource_probe => GPForum::Test::OSResourceSnapshot->new,
        ),
    );
    my $strict = _run( $no_cpu, '--strict', '--json' );
    is( decode_json( $strict->{output} )->{status},
        'fail', 'no CPU count is a failure' );
    is( $strict->{status}, 1, 'and --strict exits 1 on it' );
    like(
        $strict->{errors},
        qr/^os-preflight: [ ] \S+ [ ] CPUs: [ ] they [ ] could [ ] not/msx,
        'naming the check that failed'
    );
    is( _run( $no_cpu, '--json' )->{status}, 1, 'as the default always did' );
};

done_testing();

sub _one_cpu (%options) {
    return GPForum::Runtime->new(
        web_processes => $CONFIGURED_WEB,
        os_profile    => GPForum::Test::OSTinyLinux->new(
            resource_probe => GPForum::Test::OSResourceSnapshot->new,
        ),
        os_feature_settings => GPForum::Config->new->os_feature_settings,
        %options,
    );
}

sub _check ( $runtime, $name ) {
    my ($check) =
      grep { $_->{name} eq $name }
      @{ GPForum::OS::Preflight->from_runtime($runtime)->report->{checks} };

    return $check // {};
}

# The command as the unit runs it, with the configuration's defaults.
sub _run ( $runtime, @arguments ) {
    my ( $output, $errors ) = ( q{}, q{} );
    my $status;
    my $command = GPForum::Command::OsPreflight->new(
        catalog => GPForum::Service::I18N::CliCatalog->new( language => 'en' ),
        config  => GPForum::Config->new,
        runtime => $runtime,
    );

    # A fix names the shell's environment outside staging and production.
    delete local $ENV{GPFORUM_ENV};
    {
        open my $stdout, '>', \$output or croak 'capture stdout';
        open my $stderr, '>', \$errors or croak 'capture stderr';
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $status = $command->run(@arguments);
        close $stdout or croak 'close stdout';
        close $stderr or croak 'close stderr';
    }

    return { output => $output, errors => $errors, status => $status };
}

1;
