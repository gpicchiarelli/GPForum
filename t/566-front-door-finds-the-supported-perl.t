# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use IPC::Open3 qw(open3);
use Symbol     qw(gensym);
use Test::More;

our $VERSION = '0.001';

# Walkthrough 2, friction 13: bin/gpforum run by an older Perl -- macOS's
# /usr/bin/perl, 5.34, first on a PATH without Homebrew's -- stopped at `use
# v5.40` with "Perl v5.40.0 required--this is only v5.34.1", and no word of
# which Perl to use. It now asks script/gpforum-system-perl for the supported
# one and runs again under it; when there is none, it says which Perl it
# found and what installs one, as gpforum.

const my $EXIT_SHIFT => 8;
const my $SYSTEM     => '/usr/bin/perl';

my $old = -x $SYSTEM && _version($SYSTEM) lt 'v5.40.0';

if ($old) {
    my $help = _run( $SYSTEM, 'bin/gpforum', 'help' );
    is( $help->{status}, 0, "$SYSTEM runs the front door" )
      or diag $help->{errors};
    like(
        $help->{output},
        qr/\A Usage: [ ] gpforum [ ]/msx,
        'under the supported Perl, which it found'
    );

    my $refused = _run( $SYSTEM, 'bin/gpforum', 'help',
        { GPFORUM_PERL => $SYSTEM, LC_ALL => 'en_US.UTF-8' } );
    is( $refused->{status}, 1, 'told to use the old one, it stops' );
    like(
        $refused->{errors},
qr/\A gpforum: [ ] Perl [ ] 5[.]\d+[.]\d+ [ ] at [ ] \Q$SYSTEM\E [ ]/msx,
        'saying which Perl it found, as gpforum'
    );
    like(
        $refused->{errors},
        qr/is [ ] older [ ] than [ ] the [ ] 5[.]40/msx,
        'and that it is too old'
    );
    like(
        $refused->{errors},
        qr/^ [ ]{4} Fix: [ ] /msx,
        'and what installs one'
    );
}
else {
    note "no Perl older than 5.40 at $SYSTEM to run the front door with";
}

my $named = _run( 'script/gpforum-system-perl', '--require', '--as', 'gpforum',
    { GPFORUM_PERL => '/nonexistent/perl', LC_ALL => 'en_US.UTF-8' } );
is( $named->{status}, 1, 'a Perl that is not there is refused' );
like(
    $named->{errors},
    qr/\A gpforum: [ ] GPFORUM_PERL [ ] names/msx,
    'in the name of the program that asked'
);

done_testing();

sub _version ($perl) {
    my $run = _run( $perl, '-e', 'print $^V' );

    return $run->{output};
}

# A program run with the environment given over this one, and none of the
# test's library paths, as an operator's shell runs it.
sub _run (@command) {
    my $environment = ref $command[-1] eq 'HASH' ? pop @command : {};
    local %ENV = ( %ENV, %{$environment} );
    delete @ENV{qw(PERL5LIB PERL5OPT)};

    my $errors = gensym;
    my $pid    = open3( my $input, my $stdout, $errors, @command );
    close $input or croak "close: $OS_ERROR";
    my $output = do { local $INPUT_RECORD_SEPARATOR = undef; <$stdout> };
    my $said   = do { local $INPUT_RECORD_SEPARATOR = undef; <$errors> };
    waitpid $pid, 0;

    return {
        errors => $said   // q{},
        output => $output // q{},
        status => $CHILD_ERROR >> $EXIT_SHIFT,
    };
}

1;
