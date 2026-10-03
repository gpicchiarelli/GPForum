# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Admin::ConsoleReader;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;

our $VERSION = '0.001';

# The console's reads over the users, the moderation queue and the async
# jobs. The role catalog, role bindings, the review pages and the permission
# gate run on PostgreSQL in t/integration/postgres-admin-authorization.t.
my $users        = GPForum::Test::ModerationResultSet->new;
my $reports      = GPForum::Test::ModerationResultSet->new;
my $outbox       = GPForum::Test::ModerationResultSet->new;
my $dead_letters = GPForum::Test::ModerationResultSet->new;
my $schema       = GPForum::Test::ModerationSchema->new(
    resultsets => {
        DeadLetter    => $dead_letters,
        OutboxMessage => $outbox,
        Report        => $reports,
        User          => $users,
    },
);

$users->create(
    {
        id                => 'user-1',
        username          => 'admin_user',
        display_name      => 'Admin User',
        email_normalized  => 'admin@example.test',
        status            => 'active',
        trust_level       => 3,
        email_verified_at => '2026-05-23T12:00:00Z',
        created_at        => '2026-05-23T12:00:00Z',
        updated_at        => '2026-05-23T12:00:00Z',
        deleted_at        => undef,
    }
);
$reports->create(
    {
        report_id                  => 'report-1',
        reporter_user_id           => 'user-2',
        target_type                => 'post',
        target_id                  => 'post-1',
        reason                     => 'spam',
        details                    => 'links',
        status                     => 'open',
        assigned_moderator_user_id => undef,
        created_at                 => '2026-05-23T12:00:00Z',
        resolved_at                => undef,
        resolution                 => undef,
    }
);
$outbox->create(
    {
        outbox_id        => 'outbox-1',
        event_id         => 'event-1',
        queue            => 'default',
        job_type         => 'notification.dispatch',
        idempotency_key  => 'notification.dispatch:event-1',
        available_at     => '2026-05-23T12:00:00Z',
        created_at       => '2026-05-23T12:00:00Z',
        locked_at        => undef,
        attempts         => 1,
        status           => 'pending',
        last_error       => undef,
        next_attempt_at  => '2026-05-23T12:00:00Z',
        locked_by        => undef,
        locked_until     => undef,
        attempt_count    => 1,
        last_error_class => undef,
    }
);
$dead_letters->create(
    {
        dead_letter_id  => 'dead-letter-1',
        source_table    => 'outbox_messages',
        source_id       => 'outbox-1',
        error_class     => 'worker_failed',
        error_message   => 'retry limit exceeded',
        retry_count     => 5,
        first_failed_at => '2026-05-23T11:00:00Z',
        last_failed_at  => '2026-05-23T12:00:00Z',
    }
);
my $console = GPForum::Service::Admin::ConsoleReader->new(
    schema           => $schema,
    readiness        => GPForum::Test::AdminRuntimeStatus->new,
    metrics_snapshot => GPForum::Test::AdminRuntimeStatus->new,
);
is( $console->list_users( { limit => 5 } )->[0]{username},
    'admin_user', 'admin console lists users' );
is( $users->last_attrs->{rows}, 5, 'admin user list applies limit' );
is( $console->async_jobs( { limit => 5 } )->{outbox_messages}[0]{outbox_id},
    'outbox-1', 'admin console lists outbox messages' );
is( $console->async_jobs( { limit => 5 } )->{dead_letters}[0]{dead_letter_id},
    'dead-letter-1', 'admin console lists dead letters' );
is(
    $console->dashboard_summary( { limit => 5 } )
      ->{moderation}{reports}[0]{report_id},
    'report-1',
    'admin console dashboard includes moderation queue'
);
is( $console->operations_status->{readiness}{status},
    'ok', 'admin console exposes health status' );
is( $console->operations_status->{benchmark}{status},
    'manual', 'admin console exposes read-only benchmark status' );

done_testing();

1;

package GPForum::Test::AdminRuntimeStatus;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

sub check {
    return {
        status => 'ok',
        checks => [ { name => 'database', status => 'ok' } ],
    };
}

sub collect {
    return {
        db_query_stats => { requests_observed => 1 },
        outbox         => { pending           => 1 },
        runtime        => { mode              => 'test' },
    };
}

1;
