# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Command::Support::EnvironmentFileEdit;

our $VERSION = '0.001';

const my $EDIT      => 'GPForum::Command::Support::EnvironmentFileEdit';
const my $SECRET    => oct '640';
const my $MODE_BITS => oct '7777';
const my $OPEN      => oct '644';
const my $SHUT      => oct '500';

# gpforum secret rotate and gpforum setup change the environment file the
# same way: a line at a time, every other line kept, and the file replaced
# in one rename with its owner and mode.

subtest 'a value is set where the file has it, or where the template' => sub {
    my @lines = (
        "# a comment the operator wrote\n", "GPFORUM_ENV=staging\n",
        "GPFORUM_ENV=production\n",         "#GPFORUM_SMTP_HOST=\n",
        "GPFORUM_SESSION_SECRET=abc\n",
    );
    $EDIT->assign( \@lines, 'GPFORUM_ENV',       'development' );
    $EDIT->assign( \@lines, 'GPFORUM_SMTP_HOST', 'mail.example.org' );
    $EDIT->assign( \@lines, 'GPFORUM_SESSION_SECRETS', 'abc',
        'GPFORUM_SESSION_SECRET' );
    $EDIT->assign( \@lines, 'GPFORUM_MAIL_FROM', 'Forum <forum@example.org>' );
    is_deeply(
        \@lines,
        [
            "# a comment the operator wrote\n",
            "GPFORUM_ENV=development\n",
            "#GPFORUM_SMTP_HOST=\n",
            "GPFORUM_SMTP_HOST=mail.example.org\n",
            "GPFORUM_SESSION_SECRET=abc\n",
            "GPFORUM_SESSION_SECRETS=abc\n",
            qq{GPFORUM_MAIL_FROM="Forum <forum\@example.org>"\n},
        ],
        'the last assignment replaced and the earlier one dropped, a'
          . ' commented-out line followed, a named line followed, the end'
          . ' otherwise, and a value quoted when it needs it'
    );
    is_deeply(
        $EDIT->values_of( \@lines ),
        {
            GPFORUM_ENV             => 'development',
            GPFORUM_MAIL_FROM       => 'Forum <forum@example.org>',
            GPFORUM_SESSION_SECRET  => 'abc',
            GPFORUM_SESSION_SECRETS => 'abc',
            GPFORUM_SMTP_HOST       => 'mail.example.org',
        },
        'and read back as the service reads it'
    );

    my $before = scalar @lines;
    $EDIT->remove( \@lines, 'GPFORUM_SESSION_SECRETS' );
    ok( !exists $EDIT->values_of( \@lines )->{GPFORUM_SESSION_SECRETS},
        'a name removed is gone' );
    is( scalar @lines, $before - 1, 'and only its line' );
};

subtest 'the file is replaced whole, keeping its mode' => sub {
    my $directory = tempdir( CLEANUP => 1 );
    my $file      = "$directory/gpforum.env";

    $EDIT->replace( $file, "GPFORUM_ENV=production\n", mode => $SECRET );
    is( path($file)->slurp, "GPFORUM_ENV=production\n", 'a new file' );
    is( ( stat $file )[2] & $MODE_BITS, $SECRET,        'with the mode given' );

    chmod $OPEN, $file or BAIL_OUT("chmod: $OS_ERROR");
    $EDIT->replace( $file, "GPFORUM_ENV=staging\n" );
    is( path($file)->slurp, "GPFORUM_ENV=staging\n", 'an existing file' );
    is( ( stat $file )[2] & $MODE_BITS, $OPEN,       'keeps the mode it had' );
    is_deeply( [ glob "$directory/*" ], [$file], 'and leaves nothing beside' );

    my $refused;
    try {
        $EDIT->replace( "$directory/new.env", "x=1\n" );
    }
    catch ($error) {
        $refused = $error;
    };
    like(
        $refused,
        qr/no [ ] mode [ ] for [ ] a [ ] new [ ] file/msx,
        'a new file needs a mode'
    );

  SKIP: {
        if ( $EFFECTIVE_USER_ID == 0 ) {
            skip 'root writes any directory', 1;
        }

        my $shut = tempdir( CLEANUP => 1 );
        chmod $SHUT, $shut or BAIL_OUT("chmod: $OS_ERROR");
        my $reason;
        try {
            $EDIT->replace( "$shut/gpforum.env", "x=1\n", mode => $SECRET );
        }
        catch ($error) {
            $reason = $error;
        };
        like(
            $reason,
            qr/\A Permission [ ] denied/msx,
            q{a directory it may not write is the system's reason}
        );
        chmod oct '700', $shut or BAIL_OUT("chmod: $OS_ERROR");
    }
};

done_testing();

1;
