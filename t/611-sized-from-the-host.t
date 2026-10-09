# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English qw(-no_match_vars);
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Config::Report;
use GPForum::OS::Memory;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Doctor;
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Profile;
use GPForum::Test::HostConfig;

our $VERSION = '0.001';

# The size of a node came from the name an operator gave its environment
# (production-small, production-medium), and the cache was 4096 entries a
# process on any host. Both come from the host now (audit D1', ADR 0125): the
# web processes from its CPUs, as before, and each process's cache from its
# memory. gpforum doctor says what the host sized the node for.

const my $KIB         => 1_024;
const my $MIB         => $KIB**2;
const my $GIB         => $KIB**3;
const my $MEMINFO_KIB => 2_048_000;
const my $MAC_BYTES   => 16 * $GIB;
const my $TINY_BYTES  => $GIB / 8;
const my $SECRET      => '0123456789abcdef' x 3;

# Memory, CPUs, the entries each web process caches, and why.
const my @CACHE_CASES => (
    [ $GIB,       1, 4_096,  'the old fixed default on 1 GB, one CPU' ],
    [ $GIB / 2,   1, 2_048,  '512 MB' ],
    [ $GIB / 8,   1, 1_024,  'never fewer than 1024' ],
    [ 16 * $GIB,  8, 8_192,  '16 GB and 16 web processes' ],
    [ 256 * $GIB, 8, 16_384, 'never more than 16384' ],
    [ undef,      2, 4_096,  'memory that cannot be measured: 4096' ],
);
const my $TWO_GIB_CACHE => 4_096;
const my $SMALL_CACHE   => 2_048;
const my $TINY_CACHE    => 16;
const my $FOUR_CPUS     => 4;
const my $EIGHT_CPUS    => 8;
const my $SIXTEEN_WEB   => 16;
const my $THREE_WEB     => 3;
const my $FOUR_WEB      => 4;
const my $MIDDLE_MEMORY => 3.8 * $GIB;

subtest 'the memory is read where each system keeps it' => sub {
    my %files = (
        '/proc/meminfo' => "MemTotal:        2048000 kB\nMemFree: 1 kB\n",
        '/sys/fs/cgroup/memory.max' => "536870912\n",
    );
    my $memory = GPForum::OS::Memory->new(
        file_reader    => sub ($path) { return $files{$path} },
        command_runner => sub (@command) {
            return $command[-1] eq 'hw.memsize' ? "17179869184\n" : undef;
        },
    );
    is_deeply(
        $memory->detect('linux'),
        {
            bytes        => 512 * $MIB,
            source       => 'cgroup v2 memory.max',
            limited_from => $MEMINFO_KIB * $KIB,
        },
        q{Linux: MemTotal, held to the container's limit}
    );
    $files{'/sys/fs/cgroup/memory.max'} = "max\n";
    is(
        $memory->detect('linux')->{bytes},
        $MEMINFO_KIB * $KIB,
        'a limit of max is no limit'
    );
    is( $memory->detect('darwin')->{bytes},
        $MAC_BYTES, 'macOS: sysctl hw.memsize' );
    is_deeply(
        $memory->detect('plan9'),
        { bytes => undef, source => 'unknown' },
        'nothing answers: unknown, and nothing thrown'
    );
};

subtest 'each web process caches its part of an eighth of the memory' => sub {
    for my $case (@CACHE_CASES) {
        my ( $bytes, $cpus, $entries, $name ) = @{$case};
        my $config = GPForum::Test::HostConfig->new(
            host => { cpus => $cpus, memory_bytes => $bytes } );
        is( $config->local_cache_max_entries, $entries, $name );
    }
    is(
        GPForum::Test::HostConfig->new(
            local_cache_max_entries => $TINY_CACHE
        )->local_cache_max_entries,
        $TINY_CACHE,
        'a number is taken as it is'
    );
};

subtest 'auto is the default, and the only word it takes' => sub {
    my $default = GPForum::Config->from_environment( {} );
    is(
        $default->local_cache_max_entries,
        $default->automatic_local_cache_max_entries,
        'unset is auto'
    );
    is(
        GPForum::Config->from_environment(
            { GPFORUM_LOCAL_CACHE_MAX_ENTRIES => 'AUTO' }
        )->local_cache_max_entries,
        $default->automatic_local_cache_max_entries,
        'in any case'
    );
    throws_ok {
        GPForum::Config->from_environment(
            { GPFORUM_LOCAL_CACHE_MAX_ENTRIES => 'lots' } )
    }
    'GPForum::X::Config', 'anything else is refused';
    is(
        GPForum::Config::Report->sentence( $EVAL_ERROR->problems->[0] ),
q{GPFORUM_LOCAL_CACHE_MAX_ENTRIES must be a whole number or auto, not 'lots'.},
        'saying auto is allowed'
    );
};

subtest 'sizing names what the host sized, not what the operator set' => sub {
    my $host = { cpus => 2, memory_bytes => 2 * $GIB };
    is_deeply(
        GPForum::Test::HostConfig->new( host => $host )->sizing,
        {
            cpus         => 2,
            memory_bytes => 2 * $GIB,
            sizes        => {
                web_processes           => $FOUR_WEB,
                local_cache_max_entries => $TWO_GIB_CACHE
            },
        },
        'both sizes from the host'
    );
    is_deeply(
        GPForum::Test::HostConfig->new(
            host          => $host,
            web_processes => $THREE_WEB
        )->sizing->{sizes},
        { local_cache_max_entries => $TWO_GIB_CACHE },
        'a web process count set by hand is the operator, not the host'
    );
};

subtest 'a small host meets the floors of the profile it runs' => sub {
    my $tiny = GPForum::Test::HostConfig->new(
        environment    => 'production',
        session_secret => $SECRET,
        host           => { cpus => 1, memory_bytes => $TINY_BYTES },
    );
    my $result = GPForum::Service::Operations::Profile->new->evaluate($tiny);
    ok( $result->{ok}, 'one CPU and 128 MB pass production' )
      or diag explain $result->{errors};
    my $undersized = GPForum::Test::HostConfig->new(
        environment             => 'production',
        session_secret          => $SECRET,
        local_cache_max_entries => $TINY_CACHE,
        host => { cpus => $FOUR_CPUS, memory_bytes => $MAC_BYTES },
    );
    ok(
        GPForum::Service::Operations::Profile->new->evaluate($undersized)
          ->{errors}{local_cache_max_entries},
        'a cache set below what the host is sized for is still a floor miss'
    );
};

subtest 'doctor says what the node is sized for' => sub {
    my %sizing = (
        cpus         => 1,
        memory_bytes => $GIB / 2,
        sizes        =>
          { web_processes => 2, local_cache_max_entries => $SMALL_CACHE },
    );
    is(
        _sized( 'en', \%sizing ),
'sized for 1 CPU, 512 MB: 2 web processes, 2048 cache entries a process',
        'in English'
    );
    is(
        _sized(
            'it',
            { %sizing, cpus => $FOUR_CPUS, memory_bytes => $MIDDLE_MEMORY }
        ),
        'dimensionato per 4 CPU, 3.8 GB: 2 processi web, 2048 voci di cache'
          . ' per processo',
        'and in Italian'
    );
    is(
        _sized(
            'en',
            {
                %sizing,
                cpus         => $EIGHT_CPUS,
                memory_bytes => undef,
                sizes        => { web_processes => $SIXTEEN_WEB }
            }
        ),
        'sized for 8 CPUs: 16 web processes',
        'without the memory when it cannot be measured'
    );
    is( _sized( 'en', { %sizing, sizes => {} } ),
        undef, 'and nothing when the operator set both' );
};

done_testing();

# The line doctor's settings check adds for a sizing.
sub _sized ( $language, $sizing ) {
    my $catalog =
      GPForum::Service::I18N::CliCatalog->new( language => $language );
    my %environment = ( GPFORUM_ENV => 'development' );
    my $doctor      = GPForum::Service::Operations::Doctor->new(
        catalog     => $catalog,
        environment => \%environment,
        probes      => {
            sizing => sub { return $sizing },
            tls    => sub { return 1 },
        },
    );
    my $findings =
      GPForum::Service::Operations::Findings->new( catalog => $catalog );
    $doctor->settings( \%environment, $findings );
    my ($line) =
      grep { /\A (?: sized | dimensionato ) /msx }
      map { $_->{message} } @{ $findings->document };

    return $line;
}

1;
