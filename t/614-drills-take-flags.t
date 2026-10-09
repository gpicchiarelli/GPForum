# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::File qw(path);
use Symbol     qw(gensym);
use Test::More;

our $VERSION = '0.001';

# The drills and the evidence helper took their ports, directories and output
# from variables -- GPFORUM_PITR_PORT, GPFORUM_STANDBY_DIR,
# GPFORUM_EVIDENCE_DIR -- where every other command takes flags (audit 2.2,
# D4'). They take flags now. The old variables still work until v0.3.0, each
# with one line naming the flag that replaces it. No case here starts a
# cluster: each stops at its arguments.

const my $USAGE        => 2;
const my $STATUS_SHIFT => 8;
const my %DRILL => (
    'script/pitr-drill' => {
        flags => [qw(--port --dir --keep)],
        old   => { GPFORUM_PITR_PORT => '--port', GPFORUM_PITR_DIR => '--dir' },
    },
    'script/standby-drill' => {
        flags => [qw(--primary-port --standby-port --dir --keep)],
        old   => {
            GPFORUM_STANDBY_PRIMARY_PORT => '--primary-port',
            GPFORUM_STANDBY_PORT         => '--standby-port',
            GPFORUM_STANDBY_DIR          => '--dir',
        },
    },
);

for my $drill ( sort keys %DRILL ) {
    subtest $drill => sub {
        my $help = _run( {}, $drill, '--help' );
        is( $help->{status}, 0, '--help' );
        for my $flag ( @{ $DRILL{$drill}{flags} } ) {
            like( $help->{out}, qr/^ \s+ \Q$flag\E \b/msx, "offers $flag" );
        }
        unlike( $help->{out}, qr/GPFORUM_/msx, 'and names no variable' );

        my $port = ( grep { /port/msx } @{ $DRILL{$drill}{flags} } )[0];
        is( _run( {}, $drill, $port )->{status},
            $USAGE, "$port without a value is a usage error" );
        my $word = _run( {}, $drill, $port, 'many' );
        is( $word->{status}, $USAGE, "$port takes a number" );
        like( $word->{err}, qr/'many'/msx, 'and says what it was given' );

        # The drill removes its directory when it ends: one that holds files
        # is refused before anything starts, and left as it was. A relative
        # one is the caller's, not the checkout's.
        my $caller = path( tempdir( CLEANUP => 1 ) )->realpath->to_string;
        path( $caller, 'mine' )->make_path->child('notes.txt')->touch;
        my $full = _run_in( $caller, {}, $drill, '--dir', 'mine' );
        is( $full->{status}, $USAGE, '--dir naming a directory with files' );
        like(
            $full->{err},
            qr/--dir [ ] \Q$caller\E\/mine [ ] is [ ] not [ ] empty/msx,
            'is refused, named from where the drill was run'
        );
        ok( -e path( $caller, 'mine', 'notes.txt' ), 'and nothing is removed' );

        for my $old ( sort keys %{ $DRILL{$drill}{old} } ) {
            my $flag   = $DRILL{$drill}{old}{$old};
            my $value  = $flag =~ /port/msx ? 'old' : '/tmp/gpforum-old';
            my $result = _run( { $old => $value }, $drill, '--bogus' );
            my ($name) = $drill =~ m{([^/]+) \z}msx;
            is(
                ( split /\n/msx, $result->{err} )[0],
                "$name: $old is deprecated; use $flag $value",
                "$old still reads, with one line naming $flag"
            );
        }
    };
}

subtest 'script/gpforum-evidence-live' => sub {
    my $helper  = 'script/gpforum-evidence-live';
    my $printed = _run( {}, $helper, '--out', q{/tmp/it's here},
        '--env-file', '/srv/staging.env' );
    is( $printed->{status}, 0, '--out and --env-file' );
    like(
        $printed->{out},
        qr/^ evidence_dir='\/tmp\/it'\\''s [ ] here' $/msx,
        'the directory, quoted for the shell the commands are pasted into'
    );
    like(
        $printed->{out},
        qr/^ evidence_env_file='\/srv\/staging[.]env' $/msx,
        'and the env file'
    );
    like(
        $printed->{out},
        qr{--env-file [ ] "\$evidence_env_file"}msx,
        'which the printed verify reads'
    );
    unlike( $printed->{out}, qr/GPFORUM_EVIDENCE/msx,
        'with no old variable in them' );

    my $old = _run( { GPFORUM_EVIDENCE_DIR => '/var/tmp/evidence' }, $helper );
    is(
        $old->{err},
        'gpforum-evidence-live: GPFORUM_EVIDENCE_DIR is deprecated; use --out'
          . " /var/tmp/evidence\n",
        'GPFORUM_EVIDENCE_DIR still reads, in one line naming --out'
    );
    like( $old->{out}, qr/^ evidence_dir='\/var\/tmp\/evidence' $/msx,
        'and is used' );
};

done_testing();

# A script's status, standard output and standard error, run with the
# variables given and no other GPFORUM_ one.
sub _run ( $variables, @command ) {
    delete local @ENV{ grep { /\A GPFORUM_/msx } keys %ENV };
    local @ENV{ keys %{$variables} } = values %{$variables};
    my $pid = open3( my $input, my $output, my $errors = gensym, @command );
    close $input or return {};
    my ( $out, $err ) = map { _slurp($_) } $output, $errors;
    waitpid $pid, 0;

    return {
        status => $CHILD_ERROR >> $STATUS_SHIFT,
        out    => $out,
        err    => $err
    };
}

# The same, run from another directory.
sub _run_in ( $directory, $variables, $script, @arguments ) {
    my $command = path($script)->to_abs->to_string;
    my $here    = path->to_abs;
    chdir $directory or return {};
    my $result = _run( $variables, $command, @arguments );
    chdir $here or return {};

    return $result;
}

sub _slurp ($handle) {
    local $INPUT_RECORD_SEPARATOR = undef;

    my $text = <$handle>;

    return $text // q{};
}

1;
