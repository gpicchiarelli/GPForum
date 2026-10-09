# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp       qw(croak);
use Mojo::Util qw(encode);
use Test::More;

use lib 'lib';

use GPForum::Command::Support::Terminal;

our $VERSION = '0.001';

# gpforum admin create and gpforum setup ask the operator the same way: the
# question on standard error, the answer from standard input.

subtest 'a question, and the line typed after it' => sub {
    my $answers = encode( 'UTF-8',
        "https://forum.example.org\n\N{LATIN SMALL LETTER E WITH GRAVE}\n" );
    my $asked    = q{};
    my $terminal = GPForum::Command::Support::Terminal->new(
        input  => _handle( '<', \$answers ),
        prompt => _handle( '>', \$asked ),
    );

    is( $terminal->line('Public address [https://x.example]:'),
        'https://forum.example.org', 'the answer, without its newline' );
    is(
        $terminal->line('Again:'),
        "\N{LATIN SMALL LETTER E WITH GRAVE}",
        'read as UTF-8'
    );
    is( $terminal->line('Once more:'), undef, 'undef at the end of the input' );
    is(
        $asked,
        'Public address [https://x.example]: Again: Once more: ',
        'each question written before its answer is read'
    );
    ok( !$terminal->is_interactive, 'and a string is not a terminal' );
};

subtest 'a pipe is not a terminal' => sub {
    pipe my $reader, my $writer or croak 'cannot make a pipe';
    ok(
        !GPForum::Command::Support::Terminal->new( input => $reader )
          ->is_interactive,
        'so a command asks for its answers as options instead'
    );
    close $writer or croak 'cannot close the pipe';
    close $reader or croak 'cannot close the pipe';
};

done_testing();

sub _handle ( $mode, $text ) {
    open my $handle, $mode, $text or croak "cannot open a string: $mode";

    return $handle;
}

1;
