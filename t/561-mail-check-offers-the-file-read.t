# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp       qw(croak);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::MailCheck;
use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Test::SendmailFound;

our $VERSION = '0.001';

# Walkthrough 2, frictions 3 and 12: `gpforum --env-file F mail-check`
# offered `gpforum mail-check --send --to you@example.com --human`. Typed as
# offered, it checked the host's file instead of F, as doctor's and status's
# offers no longer do; and it sent the probe to an example domain that takes
# no mail, one doctor refuses everywhere else.

local $ENV{LC_ALL} = 'en_US.UTF-8';
my $file = path( tempdir( CLEANUP => 1 ), 'staging.env' );
$file->spew("GPFORUM_ENV=staging\n");
GPForum::Command::Support::ServiceEnvironment->new(
    file        => "$file",
    environment => {},
)->load;

my $human = _run( default_format => 'human' );
is( $human->{status}, 0, 'the dry run proves what it can' );
ok(
    index( $human->{output},
            "send one to yourself: gpforum --env-file $file mail-check --send"
          . " --to ADDRESS --human\n" ) >= 0,
    'and offers the --send that reads the same file, to an address to fill in'
) or diag $human->{output};
unlike( $human->{output}, qr/example[.]com/msx,
    'with no example address doctor would refuse' );

done_testing();

sub _run (%options) {
    my $command = GPForum::Command::MailCheck->new(
        check => GPForum::Test::SendmailFound->new,
        %options,
    );
    my ( $output, $errors ) = ( q{}, q{} );
    my $status;
    {
        open my $stdout, '>', \$output or croak 'capture stdout';
        open my $stderr, '>', \$errors or croak 'capture stderr';
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $status = $command->run;
        close $stdout or croak 'close stdout';
        close $stderr or croak 'close stderr';
    }
    utf8::decode($output);

    return { errors => $errors, output => $output, status => $status };
}

1;
