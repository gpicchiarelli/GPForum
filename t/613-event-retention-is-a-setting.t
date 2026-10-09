# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use List::Util qw(uniq);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Service::Admin::Settings;
use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Service::Operations::ScheduledJobs;
use GPForum::Test::FixedClock;
use GPForum::Test::RetentionController;

our $VERSION = '0.001';

# How long the event log is kept came with the size profile an operator named
# -- 365 days in production-small, 730 in production-medium, 30 in
# development -- and nothing said so. It is a setting of its own now,
# GPFORUM_EVENT_RETENTION_DAYS, at production-small's 365 everywhere; the
# partitions job's horizon is the lookahead the partition timer keeps (audit
# D1', ADR 0125).

const my $DEFAULT_DAYS => 365;
const my $LONGER_DAYS  => 730;
const my $LOOKAHEAD    => 3;
const my $SECRET       => 's' x 64;

subtest 'a plain setting, the same in every environment' => sub {
    for my $environment (qw(development staging production production-medium)) {
        is(
            GPForum::Config->from_environment(
                {
                    GPFORUM_ENV             => $environment,
                    GPFORUM_PUBLIC_BASE_URL => 'https://forum.gpforum.test',
                    GPFORUM_MAIL_FROM       => 'forum@forum.gpforum.test',
                    GPFORUM_METRICS_TOKEN   => 'token',
                    GPFORUM_SESSION_SECRET  => $SECRET,
                }
            )->event_retention_days,
            $DEFAULT_DAYS,
            "$environment keeps the event log $DEFAULT_DAYS days"
        );
    }
    is(
        GPForum::Config->from_environment(
            { GPFORUM_EVENT_RETENTION_DAYS => $LONGER_DAYS }
        )->event_retention_days,
        $LONGER_DAYS,
        'set, it is what is set'
    );
    ok(
        grep( { $_ eq 'GPFORUM_EVENT_RETENTION_DAYS' }
            @{ GPForum::Service::Admin::Settings->env_names } ),
        'and the settings page lists it'
    );
};

subtest 'the partitions job reads it, and the timer horizon' => sub {
    my $runner = GPForum::Service::Operations::ScheduledJobs->from_controller(
        _controller(
            GPForum::Config->new( event_retention_days => $LONGER_DAYS )
        )
    );
    is_deeply(
        $runner->profile,
        { event_retention_days => $LONGER_DAYS },
        'the retention the configuration sets'
    );

    my $evidence = $runner->partition_evidence( {} );
    is(
        scalar uniq( map { $_->{range_start} } @{ $evidence->{plans} } ),
        GPForum::Service::Operations::PartitionLifecycle->new->lookahead_months,
        'planned over the lookahead the timer keeps'
    );
    is(
        GPForum::Service::Operations::PartitionLifecycle->new->lookahead_months,
        $LOOKAHEAD, q{three months, production-small's horizon}
    );
};

done_testing();

# The few things ScheduledJobs->from_controller asks a controller for.
sub _controller ($config) {
    return GPForum::Test::RetentionController->new(
        config => $config,
        clock  => GPForum::Test::FixedClock->new,
    );
}

1;
