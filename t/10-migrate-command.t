# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Command::Migrate;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;

const my $EXPECTED_TESTS => 12;

plan tests => $EXPECTED_TESTS;

my $command = GPForum::Command::Migrate->new;
my $output  = q{};

open my $stdout, '>', \$output
  or croak 'failed to capture stdout';

{
    local *STDOUT = $stdout;

    is( $command->run('--plan'), 0, 'plan command returns success' );
}
close $stdout
  or croak 'failed to close stdout capture';

like(
    $output,
    qr/001 [ ] core [ ] identity/msx,
    'plan command prints first migration'
);
like(
    $output,
    qr/004 [ ] platform [ ] governance/msx,
    'plan command prints governance migration'
);
like(
    $output,
    qr/005 [ ] notifications [ ] subscriptions/msx,
    'plan command prints notifications migration'
);
like(
    $output,
    qr/006 [ ] attachments/msx,
    'plan command prints attachments migration'
);
like(
    $output,
    qr/007 [ ] advanced [ ] community/msx,
    'plan command prints advanced community migration'
);
like(
    $output,
    qr/008 [ ] moderation [ ] review/msx,
    'plan command prints moderation review migration'
);
like(
    $output,
    qr/009 [ ] admin [ ] authorization/msx,
    'plan command prints admin authorization migration'
);
like(
    $output,
    qr/010 [ ] import [ ] export/msx,
    'plan command prints import export migration'
);
like( $output, qr/011 [ ] plugins/msx,
    'plan command prints plugins migration' );

is(
    _usage_status(
        sub {
            $command->run('--unknown');
        }
    ),
    $EXIT_USAGE,
    'unknown migration command fails with usage'
);

# A usage error is no longer an exception: the command returns the documented
# exit status and prints the usage text to stderr, which is what an operator
# and a wrapper script can both act on.
sub _usage_status {
    my ($code) = @_;

    my $errors = q{};
    open my $capture, '>', \$errors or croak 'capture stderr';
    my $status;
    {
        local *STDERR = $capture;
        $status = $code->();
    }
    close $capture or croak 'close stderr';
    like( $errors, qr/Usage/msx, 'the usage text goes to stderr' );

    return $status;
}

1;
