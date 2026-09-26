# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::AttachmentFixtures;

use strict;
use warnings;

use File::Temp qw(tempdir);

use GPForum::Service::Attachment::FilesystemStorage;
use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::Store;
use GPForum::Service::Attachment::UploadPipeline;
use GPForum::Test::AttachmentResultSet;
use GPForum::Test::AttachmentSchema;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;

our $VERSION = '0.001';

# An upload pipeline over the attachment doubles and real filesystem storage,
# with a post owned by user-1 to link to. Returns the pipeline, its store and
# storage, and the attachment resultset.
sub build {
    my ( undef, %input ) = @_;

    my %resultsets = map { $_ => GPForum::Test::AttachmentResultSet->new }
      qw(Attachment AttachmentLink AttachmentVariant EventLog AuditLog
      OutboxMessage Post);
    $resultsets{Post}->create(
        {
            post_id          => 'post-99',
            author_user_id   => 'user-1',
            visibility       => 'public',
            moderation_state => 'visible',
            deleted_at       => undef,
            hidden_at        => undef,
        }
    );

    my $store = GPForum::Service::Attachment::Store->new(
        schema => GPForum::Test::AttachmentSchema->new(
            resultsets => \%resultsets
        ),
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
    );
    my $storage = GPForum::Service::Attachment::FilesystemStorage->new(
        root => tempdir( CLEANUP => 1 ) );

    return {
        attachments => $resultsets{Attachment},
        events      => $resultsets{EventLog},
        store       => $store,
        storage     => $storage,
        pipeline    => GPForum::Service::Attachment::UploadPipeline->new(
            antivirus      => $input{antivirus},
            intent_builder => GPForum::Service::Attachment::IntentBuilder->new(
                clock      => GPForum::Test::FixedClock->new,
                id_service => GPForum::Test::Id->new,
            ),
            storage => $storage,
            store   => $store,
        ),
    };
}

1;
