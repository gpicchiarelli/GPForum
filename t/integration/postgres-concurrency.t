package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Community::BookmarkStore;
use GPForum::Service::Identity::Store;
use GPForum::Service::Moderation::ActionStore;
use GPForum::Service::Moderation::ReportStore;
use GPForum::Service::Notification::SubscriptionStore;
use GPForum::Service::Operations::CommandIdempotency;
use GPForum::Service::Privacy::DeletionWorkflow;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $TOKEN_TTL       => 3_600;
const my $LOCK_TIMEOUT_MS => 10_000;
const my $SEED_USER_SQL   => 'SELECT id FROM users ORDER BY username LIMIT 2';
const my $SEED_POST_SQL => join q{ },
  'SELECT post_id FROM posts',
  q{WHERE deleted_at IS NULL AND moderation_state = 'visible'},
  'ORDER BY post_id DESC LIMIT 1';
const my $RACE_TARGET_ID   => '018f9999-0001-7000-8000-00000000c001';
const my $REPORT_TARGET_ID => '018f9999-0001-7000-8000-00000000c002';
const my $COMMAND_KEY      => '018f9999-0001-7000-8000-00000000c010';
const my $HIDE_COMMAND     => '018f9999-0001-7000-8000-00000000c011';
const my $AUDIT_CORR_BASE  => 0xc100;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the PostgreSQL concurrency test';
}

local $ENV{GPFORUM_DATABASE_LOCK_TIMEOUT_MS}  = $LOCK_TIMEOUT_MS;
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;

my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};

my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0,
    'migrations apply to a clean PostgreSQL database' );
is( $prepared->{seed}, 0, 'small seed profile loads' );

my $case = _load_context($database);
_audit_chain_race($case);
_command_log_race($case);
_bookmark_unique_race($case);
_subscription_unique_race($case);
_report_open_unique_race($case);
_moderation_hide_race($case);
_privacy_approval_race($case);
_identity_token_consume_race($case);

GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _load_context {
    my ($database_info) = @_;

    my $users = $database_info->{dbh}
      ->selectall_arrayref( $SEED_USER_SQL, { Slice => {} } );
    ok( @{$users} >= GPForum::Test::PostgresHarness::worker_count(),
        'seed provides at least two users' );
    my ($post_id) = $database_info->{dbh}->selectrow_array($SEED_POST_SQL);
    ok( $post_id, 'seed provides a visible post' );

    return {
        actor_user_id  => $users->[0]{id},
        dbh            => $database_info->{dbh},
        member_user_id => $users->[1]{id},
        post_id        => $post_id,
        race_target    => $RACE_TARGET_ID,
        report_target  => $REPORT_TARGET_ID,
    };
}

sub _command_log_race {
    my ($ctx) = @_;

    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            return _run_command_probe( $ctx->{member_user_id} );
        }
    );
    _assert_workers_ok( \@outcomes, 'command_log race' );
    _assert_command_log_outcomes( \@outcomes, $ctx );

    return;
}

sub _run_command_probe {
    my ($actor_id) = @_;

    my $service = GPForum::Service::Operations::CommandIdempotency->new(
        schema => GPForum::Test::PostgresHarness::connect_schema(), );
    my $result = $service->run(
        {
            actor_id     => $actor_id,
            command_id   => $COMMAND_KEY,
            command_type => 'concurrency.probe',
            request      => { probe => 'command_log' },
        },
        sub { return { ok => 1, probe => 'done', status => 'ok' }; },
        sub {
            my ($value) = @_;
            return {
                ok     => $value->{ok},
                probe  => $value->{probe},
                status => $value->{status},
            };
        },
    );

    return {
        conflict    => $result->{conflict}    ? 1 : 0,
        in_progress => $result->{in_progress} ? 1 : 0,
        recorded    => $result->{recorded}    ? 1 : 0,
        replayed    => $result->{replayed}    ? 1 : 0,
    };
}

sub _assert_command_log_outcomes {
    my ( $outcomes, $ctx ) = @_;

    my $recorded =
      grep { $_->{result}{recorded} } @{$outcomes};
    my $settled = grep {
             $_->{result}{recorded}
          || $_->{result}{replayed}
          || $_->{result}{in_progress}
    } @{$outcomes};
    is( $recorded, 1, 'command_log race records exactly one winner' );
    is(
        $settled,
        GPForum::Test::PostgresHarness::worker_count(),
        'command_log losers replay or report in_progress'
    );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh}, 'command_log', { idempotency_key => $COMMAND_KEY }
        ),
        1,
        'command_log race keeps one command_log row'
    );

    return;
}

sub _bookmark_unique_race {
    my ($ctx) = @_;

    my $input = {
        note        => 'concurrency bookmark',
        target_id   => $ctx->{race_target},
        target_type => 'thread',
        user_id     => $ctx->{member_user_id},
    };
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            my $saved =
              GPForum::Service::Community::BookmarkStore->new(
                schema => GPForum::Test::PostgresHarness::connect_schema(), )
              ->save_bookmark($input);
            return { bookmark_id => $saved->{bookmark_id} };
        }
    );
    _assert_workers_ok( \@outcomes, 'bookmark unique race' );
    _assert_single_id( \@outcomes, 'bookmark_id', 'bookmark unique race' );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh},
            'bookmarks',
            {
                target_id   => $input->{target_id},
                target_type => $input->{target_type},
                user_id     => $input->{user_id},
            }
        ),
        1,
        'bookmark unique race keeps one row'
    );

    return;
}

sub _subscription_unique_race {
    my ($ctx) = @_;

    my $input = {
        preference  => 'all',
        target_id   => $ctx->{race_target},
        target_type => 'thread',
        user_id     => $ctx->{member_user_id},
    };
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            my $saved =
              GPForum::Service::Notification::SubscriptionStore->new(
                schema => GPForum::Test::PostgresHarness::connect_schema(), )
              ->save_subscription($input);
            return { subscription_id => $saved->{subscription_id} };
        }
    );
    _assert_workers_ok( \@outcomes, 'subscription unique race' );
    _assert_single_id( \@outcomes, 'subscription_id',
        'subscription unique race' );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh},
            'subscriptions',
            {
                target_id   => $input->{target_id},
                target_type => $input->{target_type},
                user_id     => $input->{user_id},
            }
        ),
        1,
        'subscription unique race keeps one row'
    );

    return;
}

sub _report_open_unique_race {
    my ($ctx) = @_;

    my $input = {
        details          => 'concurrency report',
        reason           => 'spam',
        reporter_user_id => $ctx->{member_user_id},
        target_id        => $ctx->{report_target},
        target_type      => 'post',
    };
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            my $report =
              GPForum::Service::Moderation::ReportStore->new(
                schema => GPForum::Test::PostgresHarness::connect_schema(), )
              ->create_report($input);
            return {
                report_id => GPForum::Test::PostgresHarness::row_value(
                    $report, 'report_id'
                )
            };
        }
    );
    _assert_workers_ok( \@outcomes, 'report open unique race' );
    _assert_single_id( \@outcomes, 'report_id', 'report open unique race' );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh},
            'reports',
            {
                reporter_user_id => $input->{reporter_user_id},
                status           => 'open',
                target_id        => $input->{target_id},
                target_type      => $input->{target_type},
            }
        ),
        1,
        'report open unique race keeps one open report'
    );

    return;
}

sub _moderation_hide_race {
    my ($ctx) = @_;

    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            return _hide_once($ctx);
        }
    );
    _assert_workers_ok( \@outcomes, 'moderation hide race' );
    _assert_single_id( \@outcomes, 'action_id', 'moderation hide race' );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh}, 'moderation_actions',
            { command_id => $HIDE_COMMAND }
        ),
        1,
        'moderation hide race keeps one action row'
    );
    my ($state) =
      $ctx->{dbh}
      ->selectrow_array( 'SELECT moderation_state FROM posts WHERE post_id = ?',
        undef, $ctx->{post_id}, );
    is( $state, 'hidden', 'moderation hide race leaves the post hidden' );

    return;
}

sub _hide_once {
    my ($ctx) = @_;

    my $hidden = GPForum::Service::Moderation::ActionStore->new(
        schema => GPForum::Test::PostgresHarness::connect_schema(), )
      ->hide_post(
        {
            actor_user_id => $ctx->{actor_user_id},
            command_id    => $HIDE_COMMAND,
            post_id       => $ctx->{post_id},
            reason        => 'concurrency hide',
        }
      );

    return {
        action_id => GPForum::Test::PostgresHarness::row_value(
            $hidden->{action}, 'moderation_action_id'
        ),
        ok       => $hidden->{ok}       ? 1 : 0,
        replayed => $hidden->{replayed} ? 1 : 0,
        skipped  => $hidden->{skipped}  ? 1 : 0,
    };
}

sub _audit_chain_race {
    my ($ctx) = @_;

    my $before =
      GPForum::Test::PostgresHarness::count_rows( $ctx->{dbh}, 'audit_log',
        {} );
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            my ($slot) = @_;
            return _append_audit( $ctx, $slot );
        }
    );
    _assert_workers_ok( \@outcomes, 'audit chain race' );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh}, 'audit_log', {}
        ),
        $before + GPForum::Test::PostgresHarness::worker_count(),
        'audit chain race appends two rows'
    );
    _assert_concurrent_audit_link( \@outcomes );
    _assert_distinct_hashes( \@outcomes );

    return;
}

sub _append_audit {
    my ( $ctx, $slot ) = @_;

    my $schema = GPForum::Test::PostgresHarness::connect_schema();
    my $recorder =
      GPForum::Infrastructure::EventRecorder->new( schema => $schema );
    my $audit = $schema->txn_do(
        sub {
            return $recorder->record_audit(
                action         => 'concurrency.audit.' . $slot,
                actor_id       => $ctx->{actor_user_id},
                correlation_id => sprintf( '018f9999-0001-7000-8000-%012x',
                    $AUDIT_CORR_BASE + $slot ),
                metadata    => { slot => $slot },
                target_id   => $ctx->{race_target},
                target_type => 'thread',
            );
        }
    );

    return {
        audit_id      => $audit->{audit_id},
        previous_hash => $audit->{previous_hash},
        record_hash   => $audit->{record_hash},
    };
}

sub _assert_concurrent_audit_link {
    my ($outcomes) = @_;

    my $audit_a = $outcomes->[0]{result};
    my $audit_b = $outcomes->[1]{result};
    _assert_no_shared_previous( $audit_a, $audit_b );
    _assert_parent_child_link( $audit_a, $audit_b );

    return;
}

sub _assert_no_shared_previous {
    my ( $audit_a, $audit_b ) = @_;

    my $prev_a = $audit_a->{previous_hash};
    my $prev_b = $audit_b->{previous_hash};
    if ( defined $prev_a && defined $prev_b && $prev_a eq $prev_b ) {
        fail('concurrent audits must not share the same previous_hash');
        return;
    }

    pass('concurrent audits do not share previous_hash');
    return;
}

sub _assert_parent_child_link {
    my ( $audit_a, $audit_b ) = @_;

    my $prev_a = $audit_a->{previous_hash} // q{};
    my $prev_b = $audit_b->{previous_hash} // q{};
    my $linked = ( $prev_a eq ( $audit_b->{record_hash} // q{x} ) )
      || ( $prev_b eq ( $audit_a->{record_hash} // q{x} ) );
    ok( $linked, 'one concurrent audit is the parent of the other' );

    return;
}

sub _assert_distinct_hashes {
    my ($outcomes) = @_;

    my %seen;
    for my $outcome ( @{$outcomes} ) {
        my $hash = $outcome->{result}{record_hash};
        ok( !$seen{$hash}++, 'concurrent audit record_hash values differ' );
    }

    return;
}

sub _privacy_approval_race {
    my ($ctx) = @_;

    my $request_id = _seed_deletion_request($ctx);
    ok( $request_id, 'privacy race seeds a deletion request' );
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            return _approve_once( $ctx, $request_id );
        }
    );
    _assert_workers_ok( \@outcomes, 'privacy approval race' );
    _assert_single_id( \@outcomes, 'erasure_job_id', 'privacy approval race' );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh}, 'erasure_jobs',
            { deletion_request_id => $request_id }
        ),
        1,
        'privacy approval race keeps one erasure job row'
    );

    return;
}

sub _seed_deletion_request {
    my ($ctx) = @_;

    my $workflow = GPForum::Service::Privacy::DeletionWorkflow->new(
        schema => GPForum::Test::PostgresHarness::connect_schema(), );
    my $request = $workflow->request_deletion(
        {
            reason            => 'concurrency erasure',
            request_type      => 'anonymize',
            requester_user_id => $ctx->{member_user_id},
            resource_id       => $ctx->{member_user_id},
            resource_type     => 'user',
        }
    );

    return $request->{deletion_request_id};
}

sub _approve_once {
    my ( $ctx, $request_id ) = @_;

    my $approved =
      GPForum::Service::Privacy::DeletionWorkflow->new(
        schema => GPForum::Test::PostgresHarness::connect_schema(), )
      ->approve_request( $request_id, $ctx->{actor_user_id},
        'concurrency approval',
      );

    return {
        erasure_job_id => GPForum::Test::PostgresHarness::row_value(
            $approved->{job}, 'erasure_job_id'
        ),
        ok     => $approved->{ok}     ? 1 : 0,
        reused => $approved->{reused} ? 1 : 0,
    };
}

sub _identity_token_consume_race {
    my ($ctx) = @_;

    my $issued = _issue_reset_token($ctx);
    ok( $issued->{raw_token}, 'identity token race issues a raw token' );
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            return _consume_once( $issued->{raw_token} );
        }
    );
    _assert_workers_ok( \@outcomes, 'identity token consume race' );
    _assert_token_consume_outcomes( \@outcomes, $ctx, $issued->{token_id} );

    return;
}

sub _issue_reset_token {
    my ($ctx) = @_;

    my $store =
      GPForum::Service::Identity::Store->new(
        schema => GPForum::Test::PostgresHarness::connect_schema(), );

    return $store->token_store->create_token(
        {
            email_normalized => 'perf_user_race@example.invalid',
            token_type       => 'password_reset',
            ttl_seconds      => $TOKEN_TTL,
            user_id          => $ctx->{member_user_id},
        }
    );
}

sub _consume_once {
    my ($raw_token) = @_;

    my $child =
      GPForum::Service::Identity::Store->new(
        schema => GPForum::Test::PostgresHarness::connect_schema(), );
    my $consumed = $child->schema->txn_do(
        sub {
            return $child->token_store->consume_token( 'password_reset',
                $raw_token );
        }
    );

    return {
        error    => $consumed->{error} || q{},
        ok       => $consumed->{ok} ? 1 : 0,
        token_id => $consumed->{token_id} || q{},
    };
}

sub _assert_token_consume_outcomes {
    my ( $outcomes, $ctx, $token_id ) = @_;

    my $ok_count = grep { $_->{result}{ok} } @{$outcomes};
    my $used_count =
      grep { $_->{result}{error} eq 'token_used' } @{$outcomes};
    is( $ok_count,   1, 'identity token consume race succeeds once' );
    is( $used_count, 1, 'identity token consume race reports token_used once' );
    my ($used_at) =
      $ctx->{dbh}->selectrow_array(
        'SELECT used_at FROM identity_tokens WHERE token_id = ?',
        undef, $token_id, );
    ok( defined $used_at, 'identity token consume race marks used_at' );

    return;
}

sub _assert_workers_ok {
    my ( $outcomes, $label ) = @_;

    for my $index ( 0 .. $#{$outcomes} ) {
        ok( $outcomes->[$index]{ok},
            "$label worker $index completed without exception" )
          or diag( $outcomes->[$index]{error} // 'missing error' );
    }

    return;
}

sub _assert_single_id {
    my ( $outcomes, $key, $label ) = @_;

    my %ids =
      map  { $_->{result}{$key} => 1 }
      grep { defined $_->{result}{$key} && length $_->{result}{$key} }
      @{$outcomes};
    is( scalar keys %ids, 1, "$label returns one $key" );

    return;
}

1;
