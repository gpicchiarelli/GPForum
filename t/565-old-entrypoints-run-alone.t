# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use IPC::Open3 qw(open3);
use Mojo::File qw(path);
use Symbol     qw(gensym);
use Test::More;

our $VERSION = '0.001';

const my $EXIT_SHIFT => 8;

# Walkthrough 2, friction 9: DEPLOYMENT said the old commands work "on
# their own", but bin/gpforum-outbox-dispatch typed alone died with "Can't
# locate Const/Fast.pm in @INC": only bin/gpforum ran itself again under the
# checkout's dependencies. Every bin/gpforum-* now loads
# GPForum::CLI::FrontDoor::Carton first, which does what bin/gpforum did.

my @entrypoints = sort grep { !/[.]/msx } glob 'bin/gpforum-*';
ok( scalar @entrypoints, 'the old entrypoints are there' );

for my $entrypoint ( 'bin/gpforum', @entrypoints ) {
    my @uses = path($entrypoint)->slurp =~ /^use [ ]+ ([\w:]+)/gmsx;
    my ($carton) =
      grep { $uses[$_] eq 'GPForum::CLI::FrontDoor::Carton' } 0 .. $#uses;
    my ($first) = grep {
             $uses[$_] =~ /\A (?: GPForum | Mojo | Const ) ::/msx
          && $uses[$_] ne 'GPForum::CLI::FrontDoor::Carton'
    } 0 .. $#uses;
    ok(
        defined $carton && ( !defined $first || $carton < $first ),
        "$entrypoint runs under the dependencies before it needs one"
    );
}

if ( -d 'local/lib/perl5' ) {
    my $alone =
      _run( $EXECUTABLE_NAME, 'bin/gpforum-outbox-dispatch', '--help' );
    is( $alone->{status}, 0, 'bin/gpforum-outbox-dispatch runs on its own' )
      or diag $alone->{errors};
    like(
        $alone->{output},
        qr/\A Usage: [ ] bin\/gpforum-outbox-dispatch [ ]/msx,
        'and answers as typed'
    );
    unlike(
        $alone->{errors},
        qr/Can't [ ] locate/msx,
        'with no module missing'
    );
}
else {
    note 'no local/ here to run the entrypoints under';
}

done_testing();

# A program run with none of the test's library paths, as an operator's
# shell runs it.
sub _run (@command) {
    local %ENV = %ENV;
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
