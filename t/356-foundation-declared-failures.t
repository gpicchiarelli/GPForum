# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use File::Temp qw(tempdir);
use Mojolicious;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Infrastructure::Antivirus::Clamd;
use GPForum::Infrastructure::AuditRecord;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Keyset;
use GPForum::Log;
use GPForum::Migration::Plan;
use GPForum::Migration::Runner;
use GPForum::OS::Filesystem;
use GPForum::OS::RuntimePolicy;
use GPForum::Test::DriftedMigrationDbh;
use GPForum::Test::Minion;
use GPForum::Test::MigrationSchema;
use GPForum::Test::MigrationStorage;
use GPForum::Test::MinionJob;
use GPForum::Test::NotificationDispatcher;
use GPForum::Test::SearchEventRecorder;
use GPForum::Test::SearchIndexer;
use GPForum::Worker::EventIdempotencyStore;
use GPForum::Worker::Handler::NotificationDispatch;
use GPForum::Worker::Handler::SearchIndexing;
use GPForum::Worker::Handler::ThreadActivity;
use GPForum::Worker::IdempotentJobRunner;
use GPForum::Worker::MinionGuard;
use GPForum::Worker::MinionRegistrar;
use GPForum::Service::Outbox::FailureType;
use GPForum::X::Check;
use GPForum::X::Argument;
use GPForum::X::Config;
use GPForum::X::Unavailable;

our $VERSION = '0.001';

# The foundation's failures are told apart by class (ADR 0118), not by their
# text: a class built without what it dereferences is refused when it is
# built (X::Argument), a setting out of range is X::Config, and a dependency
# that does not answer is X::Unavailable, which the outbox retries.

my %required = (
    'GPForum::Infrastructure::EventRecorder'   => [qw(schema)],
    'GPForum::Migration::Runner'               => [qw(schema)],
    'GPForum::OS::RuntimePolicy'               => [qw(config runtime)],
    'GPForum::Worker::EventIdempotencyStore'   => [qw(schema)],
    'GPForum::Worker::Handler::ThreadActivity' => [qw(schema)],
    'GPForum::Worker::IdempotentJobRunner'     => [qw(store)],
);

# The audit record's id service mints only the ids its input leaves out, so
# a record whose ids are given is built without one.
my $given = GPForum::Infrastructure::AuditRecord->new->build(
    {
        action         => 'thread.created',
        actor_id       => 'user-1',
        audit_id       => 'audit-1',
        correlation_id => 'correlation-1',
        metadata       => {},
        target_id      => 'thread-1',
        target_type    => 'thread',
    }
);
is( $given->{audit_id}, 'audit-1',
    'an audit record with its ids needs no id service' );

for my $class ( sort keys %required ) {
    my @names = @{ $required{$class} };
    is_deeply( [ $class->required_attributes ],
        \@names, "$class declares what it dereferences" );

    my $refusal = _error_of( sub { $class->new } );
    ok(
        GPForum::X::Argument->caught($refusal),
        "$class built without it is refused"
    );
    is(
        "$refusal",
        "$class requires " . join( q{, }, @names ),
        'naming what is missing'
    );
}

my %invalid = (
    antivirus     => [ 'magic', qr/^ \s* GPFORUM_ANTIVIRUS [ ] must/msx ],
    default_theme => [ 'neon',  qr/^ \s* GPFORUM_DEFAULT_THEME [ ] must/msx ],
    default_timezone =>
      [ 'Mars/Olympus', qr/^ \s* GPFORUM_DEFAULT_TIMEZONE [ ] must/msx ],
    mail_transport =>
      [ 'pigeon', qr/^ \s* GPFORUM_MAIL_TRANSPORT [ ] must/msx ],
    web_processes => [ 0, qr/^ \s* GPFORUM_WEB_PROCESSES [ ] must/msx ],
);
for my $setting ( sort keys %invalid ) {
    my ( $value, $message ) = @{ $invalid{$setting} };
    my $refusal =
      _error_of( sub { GPForum::Config->new( $setting => $value )->validate } );
    ok( GPForum::X::Config->caught($refusal),
        "an invalid $setting is refused" );
    like( "$refusal", $message, 'in words that name it' );
    is( $refusal && $refusal->failure_type,
        'permanent', 'as a failure no retry mends' );
}
my $unparsed = _error_of(
    sub { GPForum::Config->from_environment( { GPFORUM_SMTP_PORT => 'many' } ) }
);
ok( GPForum::X::Config->caught($unparsed),
    'an environment value that is no integer is refused' );
like(
    "$unparsed",
    qr/^ \s* GPFORUM_SMTP_PORT [ ] must/msx,
    'naming the variable'
);

my $socketless =
  GPForum::Infrastructure::Antivirus::Clamd->new( socket_path => undef );
ok(
    GPForum::X::Config->caught( _error_of( sub { $socketless->ping } ) ),
    'a clamd with no socket configured is a configuration failure'
);
is( $socketless->scan('bytes')->{status},
    'error', 'and its scan an error verdict, never clean' );

my $cause  = "connection refused\n";
my $absent = _error_of(
    sub {
        GPForum::Worker::MinionGuard->wrap( sub { die $cause } );    ## no critic (ErrorHandling::RequireCarping)
    }
);
ok( GPForum::X::Unavailable->caught($absent),
    'a Minion backend that fails to start is unavailable' );
is( $absent && $absent->failure_type,
    'transport', 'which the outbox treats as one to retry' );
is( $absent && $absent->cause, $cause, 'carrying the backend error' );
is(
    "$absent",
    'Minion PostgreSQL backend is unavailable: connection refused',
    'in the words operators already read'
);
my $silent =
  _error_of( sub { GPForum::Worker::MinionGuard->assert_reachable(undef) } );
ok( GPForum::X::Unavailable->caught($silent),
    'a Minion backend that does not answer a ping is unavailable' );

# A caller that breaks a foundation method's contract gets X::Argument, which
# no retry mends.
my $cursor = { sort => [ created_at => 1 ], id => [ post_id => 'p' ] };
my %broken = (
    'a keyset in no known direction' => sub {
        GPForum::Infrastructure::Keyset->after( {},
            { %{$cursor}, direction => 'sideways' } );
    },
    'a keyset over a query that already sorts' => sub {
        GPForum::Infrastructure::Keyset->after( { created_at => 1 }, $cursor );
    },
    'a keyset over a query that already has an -or' => sub {
        GPForum::Infrastructure::Keyset->after( { -or => [] }, $cursor );
    },
    'an atomic write with no path' =>
      sub { GPForum::OS::Filesystem->new->write_atomic( q{}, 'bytes' ) },
    'an atomic write with no content' =>
      sub { GPForum::OS::Filesystem->new->write_atomic( 'file', undef ) },
    'a dollar-quoted no-transaction migration' => sub {
        GPForum::Migration::Runner->statements("SELECT \$\$ x \$\$;\n");
    },
    'an outbox job with no dispatcher' => sub {
        my $minion = GPForum::Test::Minion->new;
        my $tasks  = GPForum::Worker::MinionRegistrar->new->register($minion);
        $minion->tasks->{ $tasks->{outbox} }
          ->( GPForum::Test::MinionJob->new, 1 );
    },
);
for my $case ( sort keys %broken ) {
    ok( GPForum::X::Argument->caught( _error_of( $broken{$case} ) ),
        "$case is a broken contract" );
}

my $directory = tempdir( CLEANUP => 1 );
my $unopened  = _error_of(
    sub {
        GPForum::Log->configure(
            Mojolicious->new,
            GPForum::Config->new(
                log_path => "$directory/missing/gpforum.log"
            )
        );
    }
);
ok( GPForum::X::Config->caught($unopened),
    'a log path that cannot be opened is a configuration failure' );
like(
    "$unopened",
    qr/\A unable [ ] to [ ] open [ ] the [ ] configured [ ] log [ ] path/msx,
    'naming the path'
);
ok( $unopened && $unopened->cause, 'carrying the error that opening raised' );

ok(
    GPForum::X::Config->caught(
        _error_of(
            sub {
                GPForum::Migration::Plan->new( directory => "$directory/none" )
                  ->files;
            }
        )
    ),
    'a migration directory that is not there is a configuration failure'
);

# Migration files edited after they ran fail a check, as a drill's mismatch
# does: the tree and the database disagree about what was run.
my $first_version = GPForum::Migration::Plan->new->summary->[0]{version};
my $drifted       = _error_of(
    sub {
        GPForum::Migration::Runner->new(
            schema => GPForum::Test::MigrationSchema->new(
                storage => GPForum::Test::MigrationStorage->new(
                    dbh => GPForum::Test::DriftedMigrationDbh->new(
                        applied_versions => [$first_version]
                    )
                )
            )
        )->verify_applied;
    }
);
ok( GPForum::X::Check->caught($drifted),
    'an applied migration whose file changed fails a check' );
like(
    "$drifted",
    qr/\A migration [ ] files [ ] changed/msx,
    'in the words operators already read'
);

# A reply notification the inbox did not take is retried: the outbox reads
# the declared failure type, not the words.
my $dropped = _error_of(
    sub {
        GPForum::Worker::Handler::NotificationDispatch->new(
            dispatcher => GPForum::Test::NotificationDispatcher->new(
                failed_recipients => [ { recipient_user_id => 'user-1' } ]
            )
        )->handle(
            {
                actor_id       => 'user-author',
                aggregate_id   => 'post-1',
                domain_payload => { thread_id => 'thread-1' },
                event_id       => 'event-1',
                event_type     => 'post.created',
            }
        );
    }
);
ok(
    GPForum::X::Unavailable->caught($dropped),
    'a fan-out that dropped a recipient is unavailable'
);
is( $dropped && $dropped->failure_type,
    'transport', 'which the outbox retries' );

# A thread re-index whose event has no id cannot key the next batch of its
# posts. Retrying the same message never gives it one, so it is a broken
# contract (permanent), not a failure the outbox should retry.
my $no_origin = _error_of(
    sub {
        GPForum::Worker::Handler::SearchIndexing->new(
            indexer => GPForum::Test::SearchIndexer->new(
                batch_size   => 1,
                thread_posts => { 'thread-1' => 2 },
            ),
            recorder => GPForum::Test::SearchEventRecorder->new,
        )->handle(
            {
                aggregate_id   => 'thread-1',
                aggregate_type => 'thread',
                event_type     => 'thread.moved',
            }
        );
    }
);
ok( GPForum::X::Argument->caught($no_origin),
    'a thread post batch without its origin event is a broken contract' );
is(
    "$no_origin",
    'a thread post batch needs the event that asked for it',
    'with the same message'
);
is( GPForum::Service::Outbox::FailureType->new->classify($no_origin),
    'permanent', 'which the outbox does not retry' );

done_testing();

sub _error_of {
    my ($code) = @_;

    try {
        $code->();
    }
    catch ($error) {
        return $error;
    };

    return undef;
}

1;
