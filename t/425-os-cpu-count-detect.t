# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';

use GPForum::OS::CpuCount;

our $VERSION = '0.001';

# OS::CpuCount->detect read directly, source by source and limit by limit,
# and its default command runner and file reader against real files and
# processes: t/161 reads it through each OS profile's sources.

const my $SHELL      => '/bin/sh';
const my $LIST_PATH  => 'cpu-list';
const my $QUOTA_PATH => q{cpu-max};

# 0-3, 6 and 8-9: four, one and two CPUs.
const my $SPACED_CPUS   => 7;
const my $SHELL_DEFAULT => 3;

subtest 'the first source with a positive count wins' => sub {
    my $probe = _probe(
        files => {
            mixed    => "0-7,3-1\n",
            reversed => "3-1\n",
            spaced   => " \t0-3,6,8-9 \n",
            zero     => "0\n",
        }
    );

    is_deeply(
        $probe->detect(
            [
                { name => 'untyped' },
                { name => 'unknown',  type => 'abacus' },
                { name => 'missing',  type => 'cpu_list', path => 'nowhere' },
                { name => 'reversed', type => 'cpu_list', path => 'reversed' },
                { name => 'mixed',    type => 'cpu_list', path => 'mixed' },
                { name => 'zero',     type => 'command',  command => ['zero'] },
                { name => 'spaced',   type => 'cpu_list', path    => 'spaced' },
            ],
            []
        ),
        { count => $SPACED_CPUS, source => q{spaced} },
        q{untyped, unknown, missing, reversed and zero sources are skipped,}
          . q{ and so is a list with one reversed range}
    );
    is_deeply(
        $probe->detect( undef, undef ),
        { count => 1, source => 'fallback' },
        'no source at all is one CPU'
    );
};

subtest 'a probe that dies is skipped' => sub {
    my $probe = GPForum::OS::CpuCount->new(
        file_reader    => sub { die "unreadable\n"; },
        sysconf_reader => sub { return "2\n"; },
    );

    is_deeply(
        $probe->detect(
            [
                { name => 'list',    type => 'cpuinfo', path => 'x' },
                { name => 'sysconf', type => 'sysconf' },
            ],
            []
        ),
        { count => 2, source => 'sysconf' },
        'the next source answers'
    );
};

subtest 'the first positive limit lowers the count, never raises it' => sub {
    my $probe = _probe(
        files => {
            zero   => "0 100000\n",
            half   => "50000 100000\n",
            three  => "300000 100000\n",
            spaces => "max 100000\n",
        },
        sysconf => 2,
    );
    my $sources = [ { name => 'sysconf', type => 'sysconf' } ];

    is_deeply(
        $probe->detect(
            $sources,
            [
                { name => 'missing', path => 'nowhere' },
                { name => 'zero',    path => 'zero' },
                { name => 'max',     path => 'spaces' },
                { name => 'half',    path => 'half' },
                { name => 'three',   path => 'three' },
            ]
        ),
        { count => 1, source => 'sysconf', limited_by => 'half' },
        'half a CPU rounds up to one, and the later limit is not read'
    );
    is_deeply(
        $probe->detect( $sources, [ { name => 'three', path => 'three' } ] ),
        { count => 2, source => 'sysconf' },
        'a limit above the count is not reported'
    );

    my $dying = GPForum::OS::CpuCount->new(
        file_reader    => sub { die "gone\n"; },
        sysconf_reader => sub { return 2; },
    );
    is_deeply(
        $dying->detect( $sources, [ { name => 'gone', path => 'x' } ] ),
        { count => 2, source => 'sysconf' },
        'a limit whose file cannot be read is ignored'
    );
};

subtest 'the default command runner' => sub {
    local $ENV{OMP_NUM_THREADS}  = 1;
    local $ENV{OMP_THREAD_LIMIT} = 1;
    my $probe = GPForum::OS::CpuCount->new( sysconf_reader => sub { return; } );
    my $count = sub (@command) {
        return $probe->detect(
            [ { name => 'run', type => 'command', command => [@command] } ],
            [] );
    };

    is_deeply(
        $count->(
            $SHELL, '-c', 'echo ${OMP_NUM_THREADS:-3}${OMP_THREAD_LIMIT:-}'
        ),
        { count => $SHELL_DEFAULT, source => q{run} },
        'runs the command without the OpenMP overrides'
    );
    is_deeply(
        $count->( $SHELL, '-c', 'echo 4; exit 1' ),
        { count => 1, source => 'fallback' },
        'a command that fails says nothing'
    );
    is_deeply(
        $count->( File::Spec->catfile( tempdir( CLEANUP => 1 ), 'none' ) ),
        { count => 1, source => 'fallback' },
        'neither does one that is not executable'
    );
    is_deeply(
        $count->(),
        { count => 1, source => 'fallback' },
        'nor an empty command'
    );
};

subtest 'the default file reader' => sub {
    my $directory = tempdir( CLEANUP => 1 );
    my $list      = File::Spec->catfile( $directory, $LIST_PATH );
    my $quota     = File::Spec->catfile( $directory, $QUOTA_PATH );
    _write( $list,  "0-5\n" );
    _write( $quota, "200000 100000\n" );
    my $probe = GPForum::OS::CpuCount->new( sysconf_reader => sub { return; } );

    is_deeply(
        $probe->detect(
            [
                {
                    name => 'missing',
                    type => 'cpu_list',
                    path => File::Spec->catfile( $directory, 'none' ),
                },
                { name => 'list', type => 'cpu_list', path => $list },
            ],
            [ { name => 'quota', path => $quota } ]
        ),
        { count => 2, source => 'list', limited_by => 'quota' },
        'reads the list and the quota from disk'
    );
};

done_testing();

sub _probe (%host) {
    my $files = $host{files} || {};

    return GPForum::OS::CpuCount->new(
        command_runner => sub (@command) {
            return $command[0] eq 'zero' ? "0\n" : undef;
        },
        file_reader    => sub ($path) { return $files->{$path}; },
        sysconf_reader => sub { return $host{sysconf}; },
    );
}

sub _write ( $path, $content ) {
    open my $handle, '>', $path or croak "open $path: $OS_ERROR";
    print {$handle} $content or croak "write $path: $OS_ERROR";
    close $handle            or croak "close $path: $OS_ERROR";

    return;
}

1;
