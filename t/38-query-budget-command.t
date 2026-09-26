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
use lib 't/lib';

use GPForum::Command::QueryBudget;
use GPForum::Test::QueryBudgetResultSet;
use GPForum::Test::QueryBudgetSchema;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;

const my $EXPECTED_TESTS           => 12;
const my $THREAD_VIEW_QUERY_BUDGET => 8;

plan tests => $EXPECTED_TESTS;

my $command = GPForum::Command::QueryBudget->new;
my $printed = _capture_stdout(
    sub {
        return $command->run('--print');
    }
);

like(
    $printed,
    qr/thread_view [ ] queries=8/msx,
    'query budget print shows thread view budget'
);
like(
    $printed,
    qr/search [ ] queries=2/msx,
    'query budget print shows search budget'
);
like(
    $printed,
    qr/notifications [ ] queries=4/msx,
    'query budget print shows notifications budget'
);

my $resultset = GPForum::Test::QueryBudgetResultSet->new;
my $schema =
  GPForum::Test::QueryBudgetSchema->new( budget_resultset => $resultset, );
my $sync_command = GPForum::Command::QueryBudget->new( schema => $schema );
my $sync_output  = _capture_stdout(
    sub {
        return $sync_command->run('--sync');
    }
);

like(
    $sync_output,
    qr/\A synced [ ] 24 [ ] endpoint/msx,
    'query budget sync reports synced endpoint count'
);
is( $resultset->rows->{thread_view}->get_column('max_queries'),
    $THREAD_VIEW_QUERY_BUDGET, 'query budget sync writes thread view budget' );

my $check_output = _capture_stdout(
    sub {
        return $sync_command->run('--check');
    }
);
like(
    $check_output,
    qr/\A ok [ ] endpoint [ ] query [ ] budgets/msx,
    'query budget check accepts synchronized budgets'
);

$resultset->rows->{thread_view}->update( { max_queries => 1 } );
my $drift_status = _capture_stdout_status(
    sub {
        return $sync_command->run('--check');
    }
);
is( $drift_status->{status}, 1, 'query budget check returns failure on drift' );
like( $drift_status->{output},
    qr/mismatched=thread_view/msx,
    'query budget check reports mismatched endpoint' );

is(
    _usage_status(
        sub {
            $command->run('--unknown');
        }
    ),
    $EXIT_USAGE,
    'unknown query budget command fails with usage'
);

my $script_output = _capture_command( 'script/query-budget', '--print' );
like(
    $script_output,
    qr/thread_view [ ] queries=8/msx,
    'query budget script wrapper prints thread view budget'
);
like(
    $script_output,
    qr/search [ ] queries=2/msx,
    'query budget script wrapper prints search budget'
);

sub _capture_stdout {
    my ($code) = @_;

    return _capture_stdout_status($code)->{output};
}

sub _capture_stdout_status {
    my ($code) = @_;

    my $output = q{};
    open my $stdout, '>', \$output
      or croak 'failed to capture stdout';

    my $status;
    {
        local *STDOUT = $stdout;
        $status = $code->();
    }

    close $stdout
      or croak 'failed to close stdout capture';

    return {
        output => $output,
        status => $status,
    };
}

sub _capture_command {
    my (@command) = @_;

    open my $handle, q{-|}, @command
      or croak 'failed to run query budget script';

    my $captured = q{};
    while ( my $line = <$handle> ) {
        $captured .= $line;
    }

    close $handle
      or croak 'query budget script failed';

    return $captured;
}

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
