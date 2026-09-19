package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Moderation::Workflow;
use GPForum::Test::ForumWebServices;
use Test::More;

our $VERSION = '0.001';

my $workflow = GPForum::Service::Moderation::Workflow->new(
    action_store     => GPForum::Test::ForumWebServices->new,
    report_store     => GPForum::Test::ForumWebServices->new,
    suspension_store => GPForum::Test::ForumWebServices->new,
);

my $hidden = $workflow->hide_post(
    {
        actor_user_id => 'moderator-1',
        post_id       => 'post-1',
        reason        => 'spam',
    }
);
ok( $hidden->{ok}, 'hide_post succeeds for a known post' );
is( $hidden->{stored}{action}{action_type},
    'post.hidden', 'hide_post returns the stored action' );

my $missing_reason = $workflow->hide_post(
    {
        actor_user_id => 'moderator-1',
        post_id       => 'post-1',
        reason        => q{},
    }
);
is( $missing_reason->{status}, 'invalid', 'hide_post rejects an empty reason' );
is(
    $missing_reason->{errors}{reason},
    'reason is required',
    'hide_post names the missing reason'
);

my $missing_post = $workflow->hide_post(
    {
        actor_user_id => 'moderator-1',
        post_id       => 'missing',
        reason        => 'spam',
    }
);
is( $missing_post->{status},
    'not_found', 'hide_post maps a missing post to not_found' );

my $assigned = $workflow->assign_report(
    {
        actor_user_id => 'moderator-1',
        report_id     => 'report-1',
    }
);
ok( $assigned->{ok}, 'assign_report succeeds for a known report' );

my $missing_report = $workflow->assign_report(
    {
        actor_user_id => 'moderator-1',
        report_id     => 'missing',
    }
);
is( $missing_report->{status},
    'not_found', 'assign_report maps a missing report to not_found' );

my $missing_resolution = $workflow->resolve_report(
    {
        actor_user_id => 'moderator-1',
        report_id     => 'report-1',
        resolution    => q{},
    }
);
is( $missing_resolution->{status},
    'invalid', 'resolve_report rejects an empty resolution' );

my $resolved = $workflow->resolve_report(
    {
        actor_user_id => 'moderator-1',
        report_id     => 'report-1',
        resolution    => 'handled',
    }
);
ok( $resolved->{ok}, 'resolve_report succeeds when a resolution is present' );

my $suspended = $workflow->suspend_user(
    {
        actor_user_id => 'moderator-1',
        reason        => 'abuse campaign',
        user_id       => 'user-2',
    }
);
ok( $suspended->{ok}, 'suspend_user succeeds for a known user' );

done_testing();

1;
