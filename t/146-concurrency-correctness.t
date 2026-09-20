package main;

use strict;
use warnings;

use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Community::BookmarkStore;
use GPForum::Service::Moderation::ActionStore;
use GPForum::Service::Moderation::ReportStore;
use GPForum::Service::Notification::SubscriptionStore;
use GPForum::Test::BrokenAuditSchema;
use GPForum::Test::CommunityResultSet;
use GPForum::Test::CommunitySchema;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;
use GPForum::Test::NotificationResultSet;
use GPForum::Test::NotificationSchema;
use GPForum::Test::PostStoreLockDbh;
use GPForum::Test::PostStoreLockStorage;
use GPForum::Test::Schema;

our $VERSION = '0.001';

ok(
    GPForum::Infrastructure::UniqueConflict->is_conflict(
        'duplicate key value violates unique constraint "x" (23505)'),
    'PostgreSQL unique violations are recognized'
);
ok( !GPForum::Infrastructure::UniqueConflict->is_conflict('connection reset'),
    'non-unique errors are not treated as conflicts' );

_assert_bookmark_unique_replay();
_assert_subscription_unique_replay();
_assert_report_unique_replay();
_assert_report_id_remint();
_assert_report_id_leftover();
_assert_action_command_replay();
_assert_action_id_remint();
_assert_action_id_leftover();
_assert_action_row_lock();
_assert_audit_chain_lock();
_assert_audit_lookup_errors_propagate();

done_testing();

sub _assert_bookmark_unique_replay {
    my $bookmarks = GPForum::Test::CommunityResultSet->new;
    my $store     = GPForum::Service::Community::BookmarkStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => GPForum::Test::CommunitySchema->new(
            resultsets => { Bookmark => $bookmarks },
        ),
    );
    my $input = {
        note        => 'rileggi',
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'user-1',
    };
    my $first = $store->save_bookmark($input);
    $bookmarks->find_misses(1);
    my $replay = $store->save_bookmark( { %{$input}, note => 'aggiornato' } );

    is(
        $first->{bookmark_id},
        $replay->{bookmark_id},
        'bookmark unique race returns the existing bookmark'
    );
    is( scalar @{ $bookmarks->created },
        1, 'bookmark unique race does not insert a second row' );
    is( $replay->{note}, 'aggiornato',
        'bookmark unique race restores the winning row' );

    return;
}

sub _assert_subscription_unique_replay {
    my $subscriptions = GPForum::Test::NotificationResultSet->new;
    my $store         = GPForum::Service::Notification::SubscriptionStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => GPForum::Test::NotificationSchema->new(
            resultsets => { Subscription => $subscriptions },
        ),
    );
    my $input = {
        preference  => 'all',
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'user-1',
    };
    my $first = $store->save_subscription($input);
    $subscriptions->find_misses(1);
    my $replay =
      $store->save_subscription( { %{$input}, preference => 'mentions' } );

    is(
        $first->{subscription_id},
        $replay->{subscription_id},
        'subscription unique race returns the existing subscription'
    );
    is( scalar @{ $subscriptions->created },
        1, 'subscription unique race does not insert a second row' );
    is( $replay->{preference}, 'mentions',
        'subscription unique race restores the winning row' );

    return;
}

sub _assert_report_unique_replay {
    my $reports = GPForum::Test::ModerationResultSet->new;
    my $events  = GPForum::Test::ModerationResultSet->new;
    my $outbox  = GPForum::Test::ModerationResultSet->new;
    my $audits  = GPForum::Test::ModerationResultSet->new;
    $reports->filter_search(1);
    my $store = GPForum::Service::Moderation::ReportStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => GPForum::Test::ModerationSchema->new(
            resultsets => {
                AuditLog      => $audits,
                EventLog      => $events,
                OutboxMessage => $outbox,
                Report        => $reports,
            },
        ),
    );
    my $input = {
        details          => 'link ripetuti',
        reason           => 'spam',
        reporter_user_id => 'user-1',
        target_id        => 'post-1',
        target_type      => 'post',
    };
    my $first = $store->create_report($input);
    $reports->skip_search(1);
    my $replay = $store->create_report($input);

    is(
        _row_column( $first,  'report_id' ),
        _row_column( $replay, 'report_id' ),
        'report unique race returns the open report'
    );
    is( scalar @{ $reports->created },
        1, 'report unique race does not insert a second report' );
    is( scalar @{ $events->created },
        1, 'report unique race does not emit a second created event' );
    is( scalar @{ $outbox->created },
        1, 'report unique race does not emit a second outbox row' );
    is( $audits->created->[-1]{action},
        'report.duplicate_blocked',
        'report unique race records a controlled duplicate audit' );

    return;
}

sub _assert_report_id_remint {
    my $reports = GPForum::Test::ModerationResultSet->new;
    my $events  = GPForum::Test::ModerationResultSet->new;
    my $outbox  = GPForum::Test::ModerationResultSet->new;
    my $audits  = GPForum::Test::ModerationResultSet->new;
    $reports->filter_search(1);
    $reports->create(
        {
            details          => 'altro',
            reason           => 'spam',
            report_id        => 'generated-1',
            reporter_user_id => 'other-user',
            status           => 'open',
            target_id        => 'other-post',
            target_type      => 'post',
        }
    );
    my $store = GPForum::Service::Moderation::ReportStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => GPForum::Test::ModerationSchema->new(
            resultsets => {
                AuditLog      => $audits,
                EventLog      => $events,
                OutboxMessage => $outbox,
                Report        => $reports,
            },
        ),
    );
    my $created = $store->create_report(
        {
            details          => 'link ripetuti',
            reason           => 'spam',
            reporter_user_id => 'user-1',
            target_id        => 'post-1',
            target_type      => 'post',
        }
    );

    is( _row_column( $created, 'report_id' ),
        'generated-2', 'unique report id collision remints the id' );
    is( _row_column( $created, 'reporter_user_id' ),
        'user-1', 'unique report id collision keeps this reporter' );
    is( _row_column( $created, 'target_id' ),
        'post-1', 'unique report id collision keeps this target' );
    is( scalar @{ $reports->created },
        2, 'unique report id collision inserts this report' );
    is( scalar @{ $events->created },
        1, 'unique report id collision records this created event' );
    is( $audits->created->[-1]{action},
        'report.created',
        'unique report id collision does not treat this as a duplicate' );

    return;
}

sub _assert_report_id_leftover {
    my $reports = GPForum::Test::ModerationResultSet->new;
    my $events  = GPForum::Test::ModerationResultSet->new;
    my $outbox  = GPForum::Test::ModerationResultSet->new;
    my $audits  = GPForum::Test::ModerationResultSet->new;
    $reports->filter_search(1);
    $reports->create(
        {
            details          => 'link ripetuti',
            reason           => 'spam',
            report_id        => 'generated-1',
            reporter_user_id => 'user-1',
            status           => 'open',
            target_id        => 'post-1',
            target_type      => 'post',
        }
    );
    $reports->skip_search(1);
    my $store = GPForum::Service::Moderation::ReportStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => GPForum::Test::ModerationSchema->new(
            resultsets => {
                AuditLog      => $audits,
                EventLog      => $events,
                OutboxMessage => $outbox,
                Report        => $reports,
            },
        ),
    );
    my $leftover = $store->create_report(
        {
            details          => 'link ripetuti',
            reason           => 'spam',
            reporter_user_id => 'user-1',
            target_id        => 'post-1',
            target_type      => 'post',
        }
    );

    is( _row_column( $leftover, 'report_id' ),
        'generated-1', 'leftover report id race keeps this report' );
    is( _row_column( $leftover, 'reporter_user_id' ),
        'user-1', 'leftover report id race keeps this reporter' );
    is( scalar @{ $reports->created },
        1, 'leftover report id race does not insert a second report' );
    is( scalar @{ $events->created },
        1, 'leftover report id race inserts the missing event' );
    is( scalar @{ $outbox->created },
        1, 'leftover report id race inserts the missing outbox' );
    is( $audits->created->[-1]{action},
        'report.created', 'leftover report id race inserts the missing audit' );

    return;
}

sub _assert_action_command_replay {
    my $posts   = GPForum::Test::ModerationResultSet->new;
    my $actions = GPForum::Test::ModerationResultSet->new;
    my $events  = GPForum::Test::ModerationResultSet->new;
    my $outbox  = GPForum::Test::ModerationResultSet->new;
    my $audits  = GPForum::Test::ModerationResultSet->new;
    $posts->create(
        {
            hidden_at        => undef,
            moderation_state => 'visible',
            post_id          => 'post-1',
        }
    );
    my $store = GPForum::Service::Moderation::ActionStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => GPForum::Test::ModerationSchema->new(
            resultsets => {
                AuditLog         => $audits,
                EventLog         => $events,
                ModerationAction => $actions,
                OutboxMessage    => $outbox,
                Post             => $posts,
            },
        ),
    );
    my $input = {
        actor_user_id => 'moderator-1',
        command_id    => 'hide-command-1',
        post_id       => 'post-1',
        reason        => 'spam',
    };
    my $first  = $store->hide_post($input);
    my $replay = $store->hide_post($input);

    ok( $first->{ok},  'first hide with command id succeeds' );
    ok( $replay->{ok}, 'retry hide with the same command id succeeds' );
    ok( $replay->{replayed},
        'retry hide with the same command id is replayed' );
    is(
        $first->{action}{moderation_action_id},
        $replay->{action}{moderation_action_id},
        'retry hide returns the original action id'
    );
    is( scalar @{ $actions->created },
        1, 'retry hide does not insert a second action' );
    is( scalar @{ $events->created },
        1, 'retry hide does not emit a second event' );
    is( scalar @{ $outbox->created },
        1, 'retry hide does not emit a second outbox row' );
    is( scalar @{ $audits->created },
        1, 'retry hide does not emit a second audit row' );

    my $other = $store->hide_post(
        {
            actor_user_id => 'moderator-1',
            command_id    => 'hide-command-2',
            post_id       => 'post-1',
            reason        => 'still spam',
        }
    );
    ok( $other->{ok}, 'hide with a new command id still succeeds' );
    ok( $other->{skipped},
        'hide with a new command id is skipped when already hidden' );
    is(
        $first->{action}{moderation_action_id},
        $other->{action}{moderation_action_id},
        'hide with a new command id returns the original action'
    );
    is( scalar @{ $actions->created },
        1, 'hide with a new command id does not insert a second action' );
    is( scalar @{ $events->created },
        1, 'hide with a new command id does not emit a second event' );

    return;
}

sub _assert_action_id_remint {
    my $posts   = GPForum::Test::ModerationResultSet->new;
    my $actions = GPForum::Test::ModerationResultSet->new;
    my $events  = GPForum::Test::ModerationResultSet->new;
    my $outbox  = GPForum::Test::ModerationResultSet->new;
    my $audits  = GPForum::Test::ModerationResultSet->new;
    $posts->create(
        {
            hidden_at        => undef,
            moderation_state => 'visible',
            post_id          => 'post-1',
        }
    );
    $actions->create(
        {
            action_type          => 'post.hidden',
            actor_user_id        => 'other-moderator',
            command_id           => 'other-command',
            moderation_action_id => 'generated-1',
            reason               => 'other',
            target_id            => 'other-post',
            target_type          => 'post',
        }
    );
    my $store = GPForum::Service::Moderation::ActionStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => GPForum::Test::ModerationSchema->new(
            resultsets => {
                AuditLog         => $audits,
                EventLog         => $events,
                ModerationAction => $actions,
                OutboxMessage    => $outbox,
                Post             => $posts,
            },
        ),
    );
    my $hidden = $store->hide_post(
        {
            actor_user_id => 'moderator-1',
            command_id    => 'hide-command-pk',
            post_id       => 'post-1',
            reason        => 'spam',
        }
    );

    ok( $hidden->{ok}, 'unique action id collision remints and hides' );
    ok( !$hidden->{replayed},
        'unique action id collision does not replay another action' );
    is( $hidden->{action}{moderation_action_id},
        'generated-2', 'unique action id collision remints the id' );
    is( $hidden->{action}{target_id},
        'post-1', 'unique action id collision keeps this target' );
    is( scalar @{ $actions->created },
        2, 'unique action id collision inserts this action' );
    is( scalar @{ $events->created },
        1, 'unique action id collision records this event' );

    return;
}

sub _assert_action_id_leftover {
    my $posts   = GPForum::Test::ModerationResultSet->new;
    my $actions = GPForum::Test::ModerationResultSet->new;
    my $events  = GPForum::Test::ModerationResultSet->new;
    my $outbox  = GPForum::Test::ModerationResultSet->new;
    my $audits  = GPForum::Test::ModerationResultSet->new;
    $posts->create(
        {
            hidden_at        => undef,
            moderation_state => 'visible',
            post_id          => 'post-1',
        }
    );
    $actions->filter_search(1);
    $actions->create(
        {
            action_type          => 'post.hidden',
            actor_user_id        => 'moderator-1',
            command_id           => 'hide-command-leftover',
            moderation_action_id => 'generated-1',
            reason               => 'spam',
            target_id            => 'post-1',
            target_type          => 'post',
        }
    );
    $actions->skip_search(1);
    my $store = GPForum::Service::Moderation::ActionStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => GPForum::Test::ModerationSchema->new(
            resultsets => {
                AuditLog         => $audits,
                EventLog         => $events,
                ModerationAction => $actions,
                OutboxMessage    => $outbox,
                Post             => $posts,
            },
        ),
    );
    my $leftover = $store->hide_post(
        {
            actor_user_id => 'moderator-1',
            command_id    => 'hide-command-leftover',
            post_id       => 'post-1',
            reason        => 'spam',
        }
    );

    ok( $leftover->{ok}, 'leftover action id race reuses this action' );
    ok( $leftover->{replayed},
        'leftover action id race does not remint this action' );
    is( $leftover->{action}{moderation_action_id},
        'generated-1', 'leftover action id race keeps this action' );
    is( $leftover->{action}{target_id},
        'post-1', 'leftover action id race keeps this target' );
    is( scalar @{ $actions->created },
        1, 'leftover action id race does not insert a second action' );
    is( scalar @{ $events->created },
        1, 'leftover action id race inserts the missing event' );
    is( scalar @{ $outbox->created },
        1, 'leftover action id race inserts the missing outbox row' );
    is( scalar @{ $audits->created },
        1, 'leftover action id race inserts the missing audit row' );

    return;
}

sub _assert_action_row_lock {
    my $posts    = GPForum::Test::ModerationResultSet->new;
    my $actions  = GPForum::Test::ModerationResultSet->new;
    my $events   = GPForum::Test::ModerationResultSet->new;
    my $outbox   = GPForum::Test::ModerationResultSet->new;
    my $audits   = GPForum::Test::ModerationResultSet->new;
    my $lock_dbh = GPForum::Test::PostStoreLockDbh->new;
    $posts->create(
        {
            hidden_at        => undef,
            moderation_state => 'visible',
            post_id          => 'post-1',
        }
    );
    my $store = GPForum::Service::Moderation::ActionStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => GPForum::Test::ModerationSchema->new(
            resultsets => {
                AuditLog         => $audits,
                EventLog         => $events,
                ModerationAction => $actions,
                OutboxMessage    => $outbox,
                Post             => $posts,
            },
            storage =>
              GPForum::Test::PostStoreLockStorage->new( dbh => $lock_dbh ),
        ),
    );
    $store->hide_post(
        {
            actor_user_id => 'moderator-1',
            post_id       => 'post-1',
            reason        => 'spam',
        }
    );

    my @row_locks =
      grep { $_->{sql} =~ m/FOR [ ] UPDATE/msx } @{ $lock_dbh->calls };
    is( scalar @row_locks, 1, 'moderation hide locks the post row' );
    like(
        $row_locks[0]{sql},
        qr/FOR [ ] UPDATE/msx,
        'moderation hide uses FOR UPDATE'
    );
    is( $row_locks[0]{bind}[0],
        'post-1', 'moderation hide locks the target post' );

    return;
}

sub _assert_audit_chain_lock {
    my $lock_dbh = GPForum::Test::PostStoreLockDbh->new;
    my $schema   = GPForum::Test::Schema->new(
        storage => GPForum::Test::PostStoreLockStorage->new( dbh => $lock_dbh ),
    );
    my $recorder = GPForum::Infrastructure::EventRecorder->new(
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    );
    my $first = $recorder->record_audit(
        action         => 'thread.created',
        actor_id       => 'user-1',
        correlation_id => 'correlation-1',
        target_id      => 'thread-1',
        target_type    => 'thread',
    );
    my $replay = $recorder->record_audit(
        action         => 'thread.updated',
        actor_id       => 'user-1',
        correlation_id => 'correlation-1',
        target_id      => 'thread-1',
        target_type    => 'thread',
    );

    is( scalar @{ $lock_dbh->calls },
        2, 'each audit append takes the chain lock' );
    like( $lock_dbh->calls->[0]{sql},
        qr/pg_advisory_xact_lock/msx,
        'audit chain lock uses a transaction advisory lock' );
    is( $replay->{previous_hash},
        $first->{record_hash},
        'advisory lock does not change audit record hashing' );
    ok( $recorder->verify_audit_record($replay),
        'chained audit still verifies after lock serialization' );

    return;
}

sub _assert_audit_lookup_errors_propagate {
    my $recorder = GPForum::Infrastructure::EventRecorder->new(
        id_service => GPForum::Test::Id->new,
        schema     => GPForum::Test::BrokenAuditSchema->new,
    );

    throws_ok(
        sub {
            $recorder->record_audit(
                action         => 'thread.created',
                actor_id       => 'user-1',
                correlation_id => 'correlation-1',
                target_id      => 'thread-1',
                target_type    => 'thread',
            );
        },
        qr/audit [ ] lookup [ ] failed/msx,
        'audit lookup errors are not swallowed'
    );

    return;
}

sub _row_column {
    my ( $row, $name ) = @_;

    if ( !$row ) {
        return;
    }
    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }
    if ( $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return;
}

1;
