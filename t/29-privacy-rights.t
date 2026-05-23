package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Privacy::DataRightsReview;
use GPForum::Service::Privacy::DeletionWorkflow;
use GPForum::Service::Privacy::RetentionHoldStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 36;
const my $ONE_ROW        => 1;
const my $TWO_ROWS       => 2;
const my $REVIEW_LIMIT   => 25;

plan tests => $EXPECTED_TESTS;

my $deletion_requests =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $deletion_actions = GPForum::Test::ModerationResultSet->new;
my $erasure_jobs =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $retention_holds =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $schema = GPForum::Test::ModerationSchema->new(
    resultsets => {
        DeletionRequest => $deletion_requests,
        DeletionAction  => $deletion_actions,
        ErasureJob      => $erasure_jobs,
        RetentionHold   => $retention_holds,
    },
);

my $clock    = GPForum::Test::FixedClock->new;
my $workflow = GPForum::Service::Privacy::DeletionWorkflow->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);

my $request = $workflow->request_deletion(
    {
        requester_user_id => 'user-1',
        resource_type     => 'user',
        resource_id       => '00000000-0000-7000-8000-000000000001',
        request_type      => 'anonymize',
        reason            => 'user requested account deletion',
    }
);

is( $request->{deletion_request_id},
    'generated-1', 'deletion request id is generated' );
is( $request->{requester_user_id},
    'user-1', 'deletion request stores requester' );
is( $request->{resource_type}, 'user',
    'deletion request stores resource type' );
is(
    $request->{resource_id},
    '00000000-0000-7000-8000-000000000001',
    'deletion request stores resource id'
);
is( $request->{request_type},
    'anonymize', 'deletion request stores request type' );
is( $request->{status}, 'pending', 'deletion request starts pending' );
is( $request->{created_at},
    '2026-05-23T12:00:00Z', 'deletion request stores timestamp' );
is( scalar @{ $deletion_requests->created },
    $ONE_ROW, 'deletion request row is inserted' );

my $approved = $workflow->approve_request( 'generated-1', 'admin-1' );
is( $approved->{request_id}, 'generated-1', 'approval returns request id' );
is( $approved->{action}{deletion_action_id},
    'generated-2', 'approval action id is generated' );
is( $approved->{action}{actor_id}, 'admin-1', 'approval action stores actor' );
is( $approved->{action}{action_type}, 'held', 'approval records hold action' );
is( $approved->{job}{erasure_job_id},
    'generated-3', 'erasure job id is generated' );
is( $approved->{job}{status}, 'pending', 'erasure job starts pending' );
is( $deletion_requests->find('generated-1')->get_column('status'),
    'approved', 'deletion request row is approved' );
is( scalar @{ $deletion_actions->created },
    $ONE_ROW, 'approval action is inserted' );
is( scalar @{ $erasure_jobs->created }, $ONE_ROW, 'erasure job is inserted' );

my $completed = $workflow->complete_job( 'generated-3', 'worker-1' );
is( $completed->{erasure_job_id}, 'generated-3', 'completion returns job id' );
is( $completed->{action}{deletion_action_id},
    'generated-4', 'completion action id is generated' );
is( $completed->{action}{action_type},
    'anonymized', 'completion records anonymization action' );
is( $erasure_jobs->find('generated-3')->get_column('status'),
    'done', 'erasure job row is completed' );
is( $deletion_requests->find('generated-1')->get_column('status'),
    'completed', 'deletion request row is completed' );
is( scalar @{ $deletion_actions->created },
    $TWO_ROWS, 'completion action is inserted' );

my $holds = GPForum::Service::Privacy::RetentionHoldStore->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);
my $hold = $holds->create_hold(
    {
        resource_type => 'user',
        resource_id   => '00000000-0000-7000-8000-000000000001',
        reason        => 'legal investigation',
        created_by    => 'admin-2',
    }
);
is( $hold->{retention_hold_id},
    'generated-1', 'retention hold id is generated' );
is( $hold->{resource_type}, 'user', 'retention hold stores resource type' );
is( $hold->{reason}, 'legal investigation', 'retention hold stores reason' );
is( $hold->{created_by}, 'admin-2',         'retention hold stores creator' );
is( scalar @{ $retention_holds->created },
    $ONE_ROW, 'retention hold row is inserted' );

my $active_holds =
  $holds->active_holds_for( 'user', '00000000-0000-7000-8000-000000000001',
    $REVIEW_LIMIT, );
is( scalar @{$active_holds}, $ONE_ROW, 'active holds can be listed' );
is( $retention_holds->last_attrs->{rows},
    $REVIEW_LIMIT, 'active holds apply limit' );

my $review =
  GPForum::Service::Privacy::DataRightsReview->new( schema => $schema );
my $pending = $review->pending_deletion_requests( { limit => $REVIEW_LIMIT } );
is( scalar @{$pending}, 0,
    'completed requests are absent from pending review' );
is( $deletion_requests->last_query->{status},
    'pending', 'pending review filters by status' );
is( $deletion_requests->last_attrs->{rows},
    $REVIEW_LIMIT, 'pending review applies limit' );

my $done_jobs =
  $review->erasure_jobs_by_status( 'done', { limit => $REVIEW_LIMIT } );
is( scalar @{$done_jobs}, $ONE_ROW, 'completed erasure jobs can be reviewed' );
is( $erasure_jobs->last_query->{status}, 'done', 'job review filters status' );
is( $erasure_jobs->last_attrs->{rows},
    $REVIEW_LIMIT, 'job review applies limit' );

1;
