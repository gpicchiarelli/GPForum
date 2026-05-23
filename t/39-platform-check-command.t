package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::PlatformCheck;
use GPForum::OS;
use GPForum::Runtime;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Test::QueryBudgetResultSet;
use GPForum::Test::QueryBudgetSchema;
use GPForum::Test::ReadinessRuntime;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 8;
const my $FAIL_STATUS    => 1;

plan tests => $EXPECTED_TESTS;

my $local_command = GPForum::Command::PlatformCheck->new(
    runtime => GPForum::Test::ReadinessRuntime->new, );
my $local = _capture_stdout_status(
    sub {
        return $local_command->run('--local');
    }
);
is( $local->{status}, 0, 'local platform check succeeds for healthy runtime' );
like(
    $local->{output},
    qr/os_preflight [ ] status=ok/msx,
    'local platform check prints OS preflight status'
);

my $strict_command = GPForum::Command::PlatformCheck->new(
    runtime => GPForum::Runtime->new(
        os_profile => GPForum::OS->from_name('unknown'),
    ),
);
my $strict = _capture_stdout_status(
    sub {
        return $strict_command->run('--strict-local');
    }
);
is( $strict->{status}, $FAIL_STATUS,
    'strict local platform check fails on degraded OS posture' );

my $resultset = GPForum::Test::QueryBudgetResultSet->new;
my $schema =
  GPForum::Test::QueryBudgetSchema->new( budget_resultset => $resultset, );
GPForum::Service::Operations::QueryBudget->new->sync_schema($schema);

my $db_command = GPForum::Command::PlatformCheck->new(
    runtime => GPForum::Test::ReadinessRuntime->new,
    schema  => $schema,
);
my $with_db = _capture_stdout_status(
    sub {
        return $db_command->run('--with-db');
    }
);
is( $with_db->{status}, 0, 'database platform check accepts aligned budgets' );
like(
    $with_db->{output},
    qr/query_budget_drift [ ] status=ok/msx,
    'database platform check prints query budget drift status'
);

$resultset->rows->{thread_view}->update( { max_queries => 1 } );
my $with_drift = _capture_stdout_status(
    sub {
        return $db_command->run('--with-db');
    }
);
is( $with_drift->{status}, $FAIL_STATUS,
    'database platform check fails on query budget drift' );
like(
    $with_drift->{output},
    qr/query_budget_drift [ ] status=fail/msx,
    'database platform check reports drift failure'
);

throws_ok(
    sub {
        $local_command->run('--unknown');
    },
    qr/Usage/msx,
    'unknown platform check command fails with usage'
);

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

1;
