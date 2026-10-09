# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English    qw(-no_match_vars);
use IPC::Open3 qw(open3);
use Mojo::File qw(path);
use Symbol     qw(gensym);
use Test::More;

use lib 'lib';

use GPForum::Service::I18N::CliCatalog;

our $VERSION = '0.001';

# The walkthrough's `make system-perl` printed 41 lines and
# script/system-preflight 52, both ending in `perl -V` without a verdict or a
# next step; `system-preflight --help` ran the whole check, and a production
# install failed it over perlcritic, a develop tool. Each now ends with what
# it found and what to do next, in the operator's language, from the same
# catalogs as the rest of the command line.

const my $SYSTEM_PERL   => 'script/gpforum-system-perl';
const my $PREFLIGHT     => 'script/system-preflight';
const my $WORDS         => 'script/lib/words.sh';
const my $EXIT_USAGE    => 2;
const my $CROSS         => "\N{BALLOT X}";
const my $SOME_WORDS    => 10;
const my $VERDICT_LINES => 3;
const my $STATUS_SHIFT  => 8;

my $catalogs = GPForum::Service::I18N::CliCatalog->catalogs;

subtest 'the English each script carries is the catalog English' => sub {
    my $key  = qr/((?:system|findings)[.]\w+)/msx;
    my $text = qr/(?:'([^']*)'|"([^"]*)")/msx;
    my $said = qr/(?:words_say|reject) \s+ $key \s+ $text/msx;
    my %english;
    for my $file ( $SYSTEM_PERL, $PREFLIGHT, $WORDS ) {
        my $source = path($file)->slurp;
        while ( $source =~ /$said/gmsx ) {
            $english{$1} = $2 // $3;
        }
    }
    ok(
        scalar keys %english > $SOME_WORDS,
        'the scripts say their words by key'
    );
    is_deeply(
        [
            grep { ( $catalogs->{en}{$_} // q{} ) ne $english{$_} }
            sort keys %english
        ],
        [],
        'each key is in en.po with the same English'
    );
    is_deeply( [ grep { !exists $catalogs->{it}{$_} } sort keys %english ],
        [], 'and in it.po' );
};

subtest 'the shell reads the language as the Perl does' => sub {
    for my $environment (
        { LANG => 'it_IT.UTF-8' },
        { LANG => 'it' },
        { LANG => 'en_GB.UTF-8' },
        { LANG => 'C' },
        {},
        { LANG => 'it_IT.UTF-8', LC_ALL      => 'C' },
        { LANG => 'en_US.UTF-8', LC_MESSAGES => 'it_IT' },
        { LANG => 'italian' },
      )
    {
        my $named = join q{ },
          map { "$_=$environment->{$_}" } sort keys %{$environment};
        is(
            _run( $environment, 'sh', '-c', ". ./$WORDS; words_language" )
              ->{output},
            GPForum::Service::I18N::CliCatalog->language_of($environment)
              . "\n",
            $named || 'nothing set'
        );
    }
    is(
        _run( { LC_ALL => 'it_IT.UTF-8' }, 'sh', '-c',
                "root=.; . ./$WORDS;"
              . q{ words_say findings.summary_many x count=3} )->{output},
        "3 cose da sistemare.\n",
        'and fills in a message from it.po'
    );
};

subtest 'make system-perl ends with its verdict and the next step' => sub {
    my $found = _run( { LC_ALL => 'C' }, $SYSTEM_PERL, '--preflight' );
    is( $found->{status}, 0, 'the Perl this suite runs on is accepted' );
    my @lines = split /\n/msx, $found->{output};
    like(
        $lines[0],
        qr/\A \S+ [ ] Perl [ ] 5[.]\d+/msx,
        'the first line names it'
    );
    like(
        $lines[-1],
        qr/\A Next: [ ] make [ ] install-deps/msx,
        'the last says what to do next'
    );
    cmp_ok( scalar @lines, '<=', $VERDICT_LINES, 'in three lines, not forty' );

    my $missing = _run( { LC_ALL => 'C', GPFORUM_PERL => '/nonexistent' },
        $SYSTEM_PERL, '--preflight' );
    is( $missing->{status}, 1, 'a Perl that is not there fails' );
    my @said = split /\n/msx, $missing->{output};
    is( $said[0],
        "$CROSS GPFORUM_PERL names /nonexistent, which is not a program",
        'saying why' );
    like( $said[1], qr/\A [ ]{4} Fix: [ ] \S/msx, 'what installs one' );
    is( $said[-1], '1 thing to fix.', 'and the count' );

    my $required = _run( { LC_ALL => 'C', GPFORUM_PERL => '/nonexistent' },
        $SYSTEM_PERL, '--require' );
    is( $required->{output}, q{}, '--require prints no path for none' );
    like(
        $required->{errors},
        qr/\A gpforum-system-perl: [ ] GPFORUM_PERL [ ] names .+ Fix:/msx,
        'and says why, with the fix, to the script that asked'
    );

    is( _run( {}, $SYSTEM_PERL, '--bogus' )->{status},
        $EXIT_USAGE, 'misuse is 2' );
};

subtest 'system-preflight: help without the check, then a verdict' => sub {
    my $help = _run( { LC_ALL => 'C' }, $PREFLIGHT, '--help' );
    is( $help->{status}, 0, '--help succeeds' );
    like(
        $help->{output},
        qr/\A Usage: [ ] script\/system-preflight/msx,
        'with the usage'
    );
    unlike( $help->{output}, qr/Perl [ ] 5[.]/msx, 'and runs no check' );
    is( _run( {}, $PREFLIGHT, '--bogus' )->{status},
        $EXIT_USAGE, 'misuse is 2' );

    my $run   = _run( { LC_ALL => 'C' }, $PREFLIGHT );
    my @lines = split /\n/msx, $run->{output};
    like( $lines[0], qr/\A \S+ [ ] Perl [ ] 5[.]/msx, 'the Perl first' );
    like(
        $lines[-1],
qr/\A (?: Nothing [ ] to [ ] fix | \d+ [ ] things? [ ] to [ ] fix )[.]\z/msx,
        'and the count last'
    );
    unlike(
        $run->{output},
        qr/perlcritic|--- [ ] perl [ ] -V/msx,
        'without perlcritic, which a production install leaves out,'
          . ' or perl -V'
    );
};

done_testing();

# A program's status, stdout and stderr, under the environment given and
# nothing of the suite's locale.
sub _run ( $environment, @command ) {
    local @ENV{qw(LC_ALL LC_MESSAGES LANG GPFORUM_PERL)} = ();
    delete @ENV{qw(LC_ALL LC_MESSAGES LANG GPFORUM_PERL)};
    local @ENV{ keys %{$environment} } = values %{$environment};

    my $errors = gensym;
    my $pid    = open3( my $input, my $output, $errors, @command );
    close $input or BAIL_OUT("cannot close the input of @command");
    my $out = do { local $INPUT_RECORD_SEPARATOR = undef; <$output> }
      // q{};
    my $err = do { local $INPUT_RECORD_SEPARATOR = undef; <$errors> }
      // q{};
    waitpid $pid, 0;
    my $status = $CHILD_ERROR >> $STATUS_SHIFT;
    utf8::decode($out);
    utf8::decode($err);

    return { status => $status, output => $out, errors => $err };
}

1;
