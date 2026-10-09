# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use Mojo::File qw(path tempdir);
use Test::More;

our $VERSION = '0.001';

const my $EXIT_CODE_SHIFT => 8;

# The gates script/architecture-check adds to keep what the subtraction sweep
# removed (ADR 0117, ADR 0118), each run on a scratch tree that breaks it and
# on one that does not. t/34 runs the whole script on the real tree, where
# every gate passes, so it cannot show that a gate would fail.

my $SCRIPT = path('script/architecture-check')->to_abs;

# The frontend file the retired-idiom gate allowlists, as it is today. Its
# entry must keep firing, so every scratch tree carries it.
my $ALLOWLISTED = <<'PERL';
package GPForum::ViewModel::Forum::Page;
use v5.40;
sub summary ($self) {
    my $summary = eval { return $self->lookup };
    if ($EVAL_ERROR) {
        return undef;
    }
    return $summary;
}
1;
PERL

# Runs one check in a scratch tree holding the files given (path => text) and
# returns its exit code and what it printed.
sub _run_check ( $check, %files ) {
    my $root = tempdir( 'gpforum-architecture-XXXXX', TMPDIR => 1 );
    $files{'lib/GPForum/ViewModel/Forum/Page.pm'} //= $ALLOWLISTED;
    for my $name ( sort keys %files ) {
        my $file = $root->child( split m{/}msx, $name );
        $file->dirname->make_path;
        $file->spew( $files{$name} );
    }

    open my $output, q{-|}, 'sh', '-c', 'cd "$1" && exec sh "$2" "$3" 2>&1',
      'sh', $root->to_string, $SCRIPT->to_string, $check
      or croak "cannot run $SCRIPT: $OS_ERROR";
    my $text = do { local $INPUT_RECORD_SEPARATOR = undef; <$output> }
      // q{};

    # close is false when the check exits non-zero, which is what is asked.
    my $code = close $output ? 0 : $CHILD_ERROR >> $EXIT_CODE_SHIFT;

    return ( $code, $text );
}

sub _module ($body) {
    return "package GPForum::Service::Sample;\nuse v5.40;\n$body\n1;\n";
}

my %REFUSED = (
    'an eval block' => [ eval => 'sub f ($x) { return eval { $x->g }; }' ],
    '$EVAL_ERROR'   => [ eval_error => 'sub f ($x) { return $EVAL_ERROR; }' ],
    q{$@}           => [ eval_error => 'sub f ($x) { return $@; }' ],
    'index on an error' => [
        index_error =>
          'sub f ($error) { return index( $error, q{pkey} ) >= 0; }'
    ],
    'index on an error without parentheses' => [
        index_error => 'sub f ($error) { return index $error, q{pkey}; }'
    ],
    'a private _schema_dbh' =>
      [ schema_dbh => 'sub _schema_dbh ($self) { return undef; }' ],
    'an undeclared attribute' => [ undeclared => 'has schema => undef;' ],
    'an undeclared attribute over two lines' =>
      [ undeclared => "has schema =>\n  undef;" ],
    'undeclared attributes named in a list' =>
      [ undeclared => 'has [qw(schema clock)] => undef;' ],

    # The next declaration's comment is not this one's.
    'an undeclared attribute above an optional one' => [
        undeclared =>
          "has schema => undef;\nhas logger => undef;    # optional: logs"
    ],
    'a catch variable handed to conflict recovery' => [
        recovery => join "\n",
        'sub f ($x) {',
        '    try {',
        '        $x->g;',
        '    }',
        '    catch ($caught) {',
        '        return 1',
        '          if GPForum::Infrastructure::UniqueConflict->is_conflict(',
        '            $caught);',
        '    };',
        '    return 0;',
        '}',
    ],
);

for my $case ( sort keys %REFUSED ) {
    my ( $rule, $body ) = @{ $REFUSED{$case} };
    my ( $code, $text ) = _run_check( 'check_retired_idioms',
        'lib/GPForum/Service/Sample.pm' => _module($body) );
    is( $code, 1, "the retired-idiom gate refuses $case" );
    like( $text, qr/Sample[.]pm:\d+:[ ]\Q$rule\E:/msx,
        "naming the rule $rule" );
}

my %ACCEPTED = (
    'native try/catch' =>
"sub f (\$x) {\n    try {\n        \$x->g;\n    }\n    catch (\$e) {\n        return 0;\n    };\n    return 1;\n}",
    'an attribute marked optional' =>
      'has logger => undef;    # optional: logs only when given',
    'the idioms in POD, a comment or a heredoc' => join "\n",
    '# eval { $x } and $EVAL_ERROR, in a comment',
    'sub usage { return <<\'TEXT\'; }',
    'eval { index($error, 1) } and $@ in a heredoc',
    'TEXT',
    q{},
    '=pod',
    q{},
    'has schema => undef; eval { 1 } in POD',
    q{},
    '=cut',
);

for my $case ( sort keys %ACCEPTED ) {
    my ( $code, $text ) = _run_check( 'check_retired_idioms',
        'lib/GPForum/Service/Sample.pm' => _module( $ACCEPTED{$case} ) );
    is( $code, 0, "the retired-idiom gate accepts $case" ) or diag($text);
}

{
    my ( $code, $text ) = _run_check( 'check_retired_idioms',
        'lib/GPForum/ViewModel/Forum/Page.pm' =>
          "package GPForum::ViewModel::Forum::Page;\nuse v5.40;\n1;\n" );
    is( $code, 1, 'an allowlist entry that no longer fires fails the gate' );
    like(
        $text,
        qr{Page[.]pm:eval:[ ]allowlisted,[ ]but[ ]no[ ]longer[ ]found}msx,
        'and says which entry to remove'
    );
}

# A heredoc's lines sit at column 0 whatever block holds them. Read as code,
# such a line inside a catch block was taken for the block's end, and the gate
# reported a catch that does end with "};".
{
    my $heredoc = _module(
        join "\n",
        'sub f ($x) {',
        '    try {',
        '        $x->g;',
        '    }',
        '    catch ($e) {',

        # Spelled in two pieces, so the gates do not read a heredoc opener
        # in this file that no line of it ends.
        '        warn <<' . '"TEXT";',
        'failed: $e',
        'TEXT',
        '    };',
        '    return 1;',
        '}',
    );
    my ( $code, $text ) = _run_check( 'check_try_catch_closed',
        'lib/GPForum/Service/Sample.pm' => $heredoc );
    is( $code, 0, 'a heredoc at column 0 inside a catch block is not its end' )
      or diag($text);

    # A quoted terminator may follow the << after a space.
    ( my $spaced = $heredoc ) =~ s/<<(?="TEXT")/<< /msx;
    ( $code, $text ) = _run_check( 'check_try_catch_closed',
        'lib/GPForum/Service/Sample.pm' => $spaced );
    is( $code, 0, 'so is one whose quoted terminator follows a space' )
      or diag($text);

    ( my $open = $heredoc ) =~ s/^[ ]{4}[}];$/    }/msx;
    ( $code, $text ) = _run_check( 'check_try_catch_closed',
        'lib/GPForum/Service/Sample.pm' => $open );
    is( $code, 1, 'a catch block closed with a bare brace is still refused' );
}

# Text that only looks like a heredoc opener, with no line to end it, would
# leave the rest of its file unread, an eval or an open catch block included:
# both gates that read code stop on it instead, naming where it begins.
{
    my $lookalike =
      _module( join "\n", q{my $usage = 'write <<} . q{TEXT for a heredoc';},
        'sub f ($x) {', '    return eval { $x->g };', '}', );
    for my $check (qw(check_retired_idioms check_try_catch_closed)) {
        my ( $code, $text ) =
          _run_check( $check, 'lib/GPForum/Service/Sample.pm' => $lookalike );
        is( $code, 1, "$check stops on a heredoc no line ends" );
        like(
            $text,
            qr/Sample[.]pm:3:[ ]no[ ]line[ ]ends[ ]the[ ]heredoc/msx,
            'naming where it begins'
        );
    }
}

my %PROTOTYPES = (
    'a prototype' => [ 1, 'sub f ($$) { return 1; }' ],

    # Spelled in two pieces, so the gate does not find them in this file.
    'a :prototype attribute' => [ 1, 'sub f :' . 'prototype($) { return 1; }' ],
    'an anonymous :prototype' => [ 1, 'my $f = sub :' . 'prototype($) { 1 };' ],
    'a signature naming variables' =>
      [ 0, 'sub f ( $x, @rest ) { return 1; }' ],
);
for my $case ( sort keys %PROTOTYPES ) {
    my ( $refused, $body ) = @{ $PROTOTYPES{$case} };
    my ( $code,    $text ) = _run_check( 'check_subroutine_prototypes',
        'lib/GPForum/Service/Sample.pm' => _module($body) );
    is( $code, $refused,
            'the prototype gate '
          . ( $refused ? 'refuses' : 'accepts' )
          . " $case" )
      or diag($text);
}

{
    my ( $code, $text ) = _run_check( 'check_column_reader_empty_list',
        'lib/GPForum/Service/Sample.pm' =>
          _module("sub _column_name (\$row) {\n    return;\n}") );
    is( $code, 1, 'a column reader that returns the empty list is refused' );

    ( $code, $text ) = _run_check( 'check_column_reader_empty_list',
        'lib/GPForum/Service/Sample.pm' =>
          _module("sub _column_name (\$row) {\n    return undef;\n}") );
    is( $code, 0, 'one that returns undef is accepted' ) or diag($text);
}

{
    my ( $code, $text ) = _run_check('check_no_such_gate');
    is( $code, 2, 'an unknown check name is a usage error' );
}

done_testing();

1;
