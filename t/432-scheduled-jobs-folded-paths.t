# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::ScheduledJobs;
use GPForum::Service::Attachment::Store;
use GPForum::Test::ScheduledJobsApp;
use GPForum::Test::ScheduledJobsRunner;

our $VERSION = '0.001';

# The paths scheduled-jobs folded into run_once and its summary printer: the
# application, given as a code reference or as itself, built only when work
# runs; the attachment storage lent to a store without one and never over one
# it has; the jobs and limit parsed handed to the runner; and the summary line
# with ok first, each job in name order, its notes in a fixed order and a
# count it lacks printed as 0.

const my $LIMIT         => 7;
const my $DEFAULT_LIMIT => 100;
const my $DELETED       => 2;
const my $ERRORS        => 3;
const my $SCANNED       => 5;
const my $EXIT_FAILED   => 1;

_test_application_built_only_for_work();
_test_application_given_as_itself();
_test_storage_lent_to_a_store_without_one();
_test_storage_a_store_has_is_kept();
_test_runner_without_a_store();
_test_summary_line();

done_testing();

sub _test_application_built_only_for_work {
    my $runner = GPForum::Test::ScheduledJobsRunner->new;
    my $app    = GPForum::Test::ScheduledJobsApp->new( jobs => $runner );
    my $built  = 0;
    my $command =
      GPForum::Command::ScheduledJobs->new( app => sub { $built++; $app } );

    my ( $status, $output ) = _run( $command, '--help' );
    is( $status, 0, '--help succeeds' );
    is( $built,  0, 'without building the application' );

    ( $status, $output ) =
      _run( $command, '--once', '--limit', $LIMIT, '--job', 'sessions' );
    is( $status, 0, 'a run succeeds' );
    is( $built,  1, 'building the application from its code once' );
    is( $app->controllers_built, 1, 'and one controller of it' );
    is_deeply(
        $runner->runs,
        [ { jobs => ['sessions'], limit => $LIMIT } ],
        'whose runner is given the jobs and limit parsed'
    );
    is( $output, "scheduled_jobs ok=1\n", 'and the summary is printed' );

    return;
}

sub _test_application_given_as_itself {
    my $runner = GPForum::Test::ScheduledJobsRunner->new;
    my $app    = GPForum::Test::ScheduledJobsApp->new( jobs => $runner );

    my ($status) =
      _run( GPForum::Command::ScheduledJobs->new( app => $app ), '--once' );
    is( $status,                 0, 'an application given as itself runs' );
    is( $app->controllers_built, 1, 'building its controller' );
    is_deeply(
        $runner->runs,
        [ { jobs => [], limit => $DEFAULT_LIMIT } ],
        'every job, at the default limit'
    );

    return;
}

sub _test_storage_lent_to_a_store_without_one {
    my $store   = _store();
    my $storage = { name => 'the application storage' };
    _run_application( $store, $storage );
    is( $store->storage, $storage,
        'a store without storage is lent the application\'s' );

    return;
}

sub _test_storage_a_store_has_is_kept {
    my $own   = { name => 'the store\'s own storage' };
    my $store = _store( storage => $own );
    _run_application( $store, { name => 'the application storage' } );
    is( $store->storage, $own, 'a store with storage keeps its own' );

    return;
}

sub _test_runner_without_a_store {
    my ($status) = _run_application( undef, { name => 'unused' } );
    is( $status, 0, 'a runner without an attachment store runs' );

    return;
}

sub _test_summary_line {
    my $runner = GPForum::Test::ScheduledJobsRunner->new(
        summary => {
            ok    => 0,
            beta  => undef,
            gamma => $SCANNED,
            alpha => {
                deleted => $DELETED,
                error   => 'disk full',
                errors  => [ (q{x}) x $ERRORS ],
                ok      => 0,
                skipped => 'no storage',
            },
        }
    );
    my ( $status, $output ) =
      _run( GPForum::Command::ScheduledJobs->new( jobs => $runner ), '--once' );
    is( $status, $EXIT_FAILED, 'a summary that is not ok fails the run' );
    is(
        $output,
        'scheduled_jobs ok=0 alpha=2 alpha_skipped="no storage"'
          . ' alpha_error="disk full" alpha_errors=3 beta=0 gamma=5' . "\n",
        'ok first, jobs by name, notes skipped, error, errors, no count as 0'
    );

    return;
}

# A runner whose attachment store is the one given, run through an application
# that lends the storage given.
sub _run_application ( $store, $storage ) {
    my $app = GPForum::Test::ScheduledJobsApp->new(
        attachment_storage => $storage,
        jobs               =>
          GPForum::Test::ScheduledJobsRunner->new( attachment_store => $store ),
    );

    return _run( GPForum::Command::ScheduledJobs->new( app => sub { $app } ),
        '--once' );
}

# The real attachment store: its schema is never reached here.
sub _store (%attributes) {
    return GPForum::Service::Attachment::Store->new(
        schema => {},
        %attributes
    );
}

sub _run ( $command, @arguments ) {
    my $output = q{};
    open my $handle, '>', \$output or croak 'cannot capture output';
    $command->output($handle);
    my $status = $command->run(@arguments);
    close $handle or croak 'cannot close output';

    return ( $status, $output );
}

1;
