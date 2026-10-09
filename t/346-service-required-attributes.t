# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use lib 'lib';
use lib 't/lib';

use Test::More;

our $VERSION = '0.001';

# The collaborators each service dereferences without a guard. Built without
# one, the service used to die later, on the first call that reached for it,
# with "Can't call method ... on an undefined value"; now the constructor
# throws GPForum::X::Argument naming every missing attribute.
my %REQUIRED = (
    'GPForum::Service::Attachment::Delivery'       => [qw(storage store)],
    'GPForum::Service::Attachment::MediaProcessor' => [qw(storage store)],
    'GPForum::Service::Attachment::Scanner'        => [qw(storage store)],
    'GPForum::Service::Attachment::Store'          => [qw(schema)],
    'GPForum::Service::Attachment::UploadPipeline' => [qw(storage store)],
    'GPForum::Service::Attachment::Workflow'       =>
      [qw(delivery pipeline post_reader store)],
    'GPForum::Service::Discovery::FeedBuilder'         => [qw(canonical_url)],
    'GPForum::Service::Discovery::MetadataBuilder'     => [qw(canonical_url)],
    'GPForum::Service::Discovery::SitemapBuilder'      => [qw(canonical_url)],
    'GPForum::Service::I18N::Formatter'                => [qw(locale_table)],
    'GPForum::Service::Operations::CommandIdempotency' => [qw(schema)],
    'GPForum::Service::Operations::RateLimiter::PostgreSQLStore' =>
      [qw(schema)],
    'GPForum::Service::Operations::RetentionStore' => [qw(schema)],
    'GPForum::Service::Operations::TieredCache'    => [qw(l1 l2)],
    'GPForum::Service::Outbox::DeadLetterRecorder' => [qw(schema)],
    'GPForum::Service::Outbox::DeadLetterReplay'   => [qw(schema)],
    'GPForum::Service::Outbox::Dispatcher'         => [qw(schema transport)],
    'GPForum::Service::Plugin::FailureRecorder'    => [qw(schema)],
    'GPForum::Service::Plugin::HookDispatcher' => [qw(failure_recorder schema)],
    'GPForum::Service::Plugin::Registry'       => [qw(schema)],
    'GPForum::Service::Portability::ExportBundleBuilder' => [qw(schema)],
    'GPForum::Service::Portability::ImportJobStore'      => [qw(schema)],
    'GPForum::Service::Portability::LegacyIdMapper'      => [qw(schema)],
    'GPForum::Service::Projection::GenerationManager'    => [qw(schema)],
    'GPForum::Service::Projection::OffsetTracker'        => [qw(schema)],
    'GPForum::Service::Search::Indexer'                  => [qw(schema)],
    'GPForum::Service::Search::RebuildRun' => [qw(indexer schema)],
    'GPForum::Service::Search::Searcher'   => [qw(schema)],
);

for my $class ( sort keys %REQUIRED ) {
    require_ok($class);
    is_deeply( [ sort $class->required_attributes ],
        $REQUIRED{$class}, "$class declares what it dereferences" );

    my $error;
    try {
        $class->new;
    }
    catch ($caught) {
        $error = $caught;
    };
    isa_ok( $error, 'GPForum::X::Argument', "$class built with nothing" );
    is(
        "$error",
        "$class requires " . join( q{, }, $class->required_attributes ),
        'which names every missing attribute'
    );
}

done_testing();

1;
