package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::OS;
use GPForum::OS::CpuCount;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;

our $VERSION = '0.001';

const my $HOST_CPUS           => 8;
const my $AFFINITY_CPUS       => 6;
const my $ONLINE_CPUS         => 5;
const my $CPUINFO_CPUS        => 3;
const my $CONFIGURED_WORKERS  => 4;
const my $DARWIN_SYSCTL       => '/usr/sbin/sysctl';
const my $FREEBSD_SYSCTL      => '/sbin/sysctl';
const my $CGROUP_CPU_MAX      => '/sys/fs/cgroup/cpu.max';
const my $CPU_ONLINE          => '/sys/devices/system/cpu/online';
const my $PROC_CPUINFO        => '/proc/cpuinfo';
const my $ONE_AND_HALF_QUOTA  => "150000 100000\n";
const my $UNLIMITED_QUOTA     => "max 100000\n";
const my $EXPECTED_QUOTA_CPUS => 2;

_darwin_uses_sysctl();
_freebsd_uses_sysctl();
_linux_prefers_affinity();
_linux_file_fallbacks();
_linux_cgroup_quota();
_fallback_is_one();
_malformed_outputs_are_ignored();
_policy_uses_detected_cpus();

done_testing();

sub _darwin_uses_sysctl {
    my @calls;
    my $os = _with_probe(
        'darwin',
        commands => sub {
            my (@command) = @_;
            push @calls, join q{ }, @command;
            return "$HOST_CPUS\n";
        },
    );

    is( $os->cpu_count, $HOST_CPUS, 'darwin reads sysctl hw.logicalcpu' );
    is(
        $os->cpu_count_source,
        'sysctl hw.logicalcpu',
        'darwin reports the sysctl source'
    );
    is_deeply(
        \@calls,
        ["$DARWIN_SYSCTL -n hw.logicalcpu"],
        'darwin probes once and caches the answer'
    );
    $os->cpu_count;
    is( scalar @calls, 1, 'cpu count is cached per OS profile' );

    my $ncpu = _with_probe(
        'darwin',
        commands => sub {
            my (@command) = @_;
            return $command[-1] eq 'hw.ncpu' ? "$AFFINITY_CPUS\n" : undef;
        },
    );
    is( $ncpu->cpu_count, $AFFINITY_CPUS,
        'darwin falls back to sysctl hw.ncpu' );

    return;
}

sub _freebsd_uses_sysctl {
    my @calls;
    my $os = _with_probe(
        'freebsd',
        commands => sub {
            my (@command) = @_;
            push @calls, $command[0];
            return "$HOST_CPUS\n";
        },
    );

    is( $os->cpu_count, $HOST_CPUS,      'freebsd reads sysctl hw.ncpu' );
    is( $calls[0],      $FREEBSD_SYSCTL, 'freebsd uses /sbin/sysctl' );

    return;
}

sub _linux_prefers_affinity {
    my $os = _with_probe(
        'linux',
        commands => sub { return "$AFFINITY_CPUS\n"; },
        files    => {
            $CPU_ONLINE   => "0-7\n",
            $PROC_CPUINFO => _cpuinfo($HOST_CPUS),
        },
    );

    is( $os->cpu_count, $AFFINITY_CPUS,
        'linux prefers nproc, which honours sched_getaffinity' );
    is( $os->cpu_count_source, 'nproc', 'linux reports the nproc source' );

    return;
}

sub _linux_file_fallbacks {
    my $online = _with_probe(
        'linux',
        commands => sub { return; },
        files    => { $CPU_ONLINE => "0-2,4-5\n" },
    );
    is( $online->cpu_count, $ONLINE_CPUS,
        'linux parses the online CPU list when nproc is missing' );

    my $cpuinfo = _with_probe(
        'linux',
        commands => sub { return; },
        files    => { $PROC_CPUINFO => _cpuinfo($CPUINFO_CPUS) },
    );
    is( $cpuinfo->cpu_count, $CPUINFO_CPUS,
        'linux counts /proc/cpuinfo processors as a last file fallback' );
    is( $cpuinfo->cpu_count_source,
        $PROC_CPUINFO, 'linux reports the cpuinfo source' );

    return;
}

sub _linux_cgroup_quota {
    my $quota = _with_probe(
        'linux',
        commands => sub { return "$HOST_CPUS\n"; },
        files    => { $CGROUP_CPU_MAX => $ONE_AND_HALF_QUOTA },
    );
    is( $quota->cpu_count, $EXPECTED_QUOTA_CPUS,
        'linux cgroup v2 quota caps the CPU count (rounded up)' );
    is(
        $quota->cpu_detection->{limited_by},
        'cgroup v2 cpu.max',
        'quota limit is reported'
    );

    my $unlimited = _with_probe(
        'linux',
        commands => sub { return "$HOST_CPUS\n"; },
        files    => { $CGROUP_CPU_MAX => $UNLIMITED_QUOTA },
    );
    is( $unlimited->cpu_count, $HOST_CPUS,
        'unlimited cgroup quota keeps the affinity count' );

    return;
}

sub _fallback_is_one {
    my $unknown = GPForum::OS->from_name('plan9');
    $unknown->cpu_probe(
        GPForum::OS::CpuCount->new( sysconf_reader => sub { return; } ) );
    is( $unknown->cpu_count, 1, 'unknown OS without sysconf falls back to 1' );
    is( $unknown->cpu_count_source, 'fallback', 'fallback source is reported' );

    my $sysconf = GPForum::OS->from_name('plan9');
    $sysconf->cpu_probe(
        GPForum::OS::CpuCount->new(
            sysconf_reader => sub { return $CPUINFO_CPUS; }
        )
    );
    is( $sysconf->cpu_count, $CPUINFO_CPUS,
        'unknown OS uses sysconf when the constant exists' );

    return;
}

sub _malformed_outputs_are_ignored {
    my $garbage = _with_probe( 'darwin',
        commands => sub { return "sysctl: unknown oid\n"; }, );
    $garbage->cpu_probe->sysconf_reader( sub { return; } );
    is( $garbage->cpu_count, 1, 'non-integer command output is ignored' );

    my $zero = _with_probe( 'linux', commands => sub { return "0\n"; } );
    is( $zero->cpu_count, 1, 'zero CPU answers are ignored' );

    my $throwing = _with_probe(
        'linux',
        commands => sub { die "probe exploded\n"; },
        files    => { $CPU_ONLINE => "garbage\n", $CGROUP_CPU_MAX => "max\n" },
    );
    is( $throwing->cpu_count, 1, 'probe exceptions and bad files fall back' );

    return;
}

sub _policy_uses_detected_cpus {
    my $os = _with_probe( 'linux', commands => sub { return "$HOST_CPUS\n"; } );
    my $config = GPForum::Config->new(
        runtime_worker_policy   => 'cap-to-cpu',
        runtime_max_web_per_cpu => 2,
        web_processes           => $CONFIGURED_WORKERS,
    );
    my $policy = GPForum::OS::RuntimePolicy->new(
        config  => $config,
        runtime => GPForum::Runtime->new(
            os_profile    => $os,
            web_processes => $CONFIGURED_WORKERS,
        ),
    );

    is( $policy->hypnotoad_config->{workers},
        $CONFIGURED_WORKERS,
        'cap-to-cpu keeps configured workers on a multi-core host' );
    is( $policy->report->{effective}{cpu_count},
        $HOST_CPUS, 'runtime report exposes the detected CPU count' );

    my $single = _with_probe( 'linux', commands => sub { return "1\n"; } );
    my $single_policy = GPForum::OS::RuntimePolicy->new(
        config  => $config,
        runtime => GPForum::Runtime->new(
            os_profile    => $single,
            web_processes => $CONFIGURED_WORKERS,
        ),
    );
    is( $single_policy->hypnotoad_config->{workers},
        2, 'cap-to-cpu still caps a single-CPU host to two workers' );

    return;
}

sub _with_probe {
    my ( $name, %input ) = @_;

    my $files = $input{files} || {};
    my $os    = GPForum::OS->from_name($name);
    $os->cpu_probe(
        GPForum::OS::CpuCount->new(
            command_runner => $input{commands},
            file_reader    => sub {
                my ($path) = @_;
                return $files->{$path};
            },
            sysconf_reader => sub { return; },
        )
    );

    return $os;
}

sub _cpuinfo {
    my ($count) = @_;

    return join q{},
      map { "processor\t: $_\nmodel name\t: test\n\n" } 0 .. $count - 1;
}

1;
