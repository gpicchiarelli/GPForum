# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::Maintenance;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Id;
use GPForum::Service::Clock;
use GPForum::Service::Search::Indexer;
use GPForum::Service::Search::RebuildRun;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;

# Every public page, and the reader caches the public pages are built from
# (the anonymous category list).
const my @PURGED_TAGS => qw(forum:public-html categories forum-index);

has cache      => undef;
has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
has indexer    => sub ($self) {
    return GPForum::Service::Search::Indexer->new( schema => $self->schema );
};
has rebuild_run => sub ($self) {
    return GPForum::Service::Search::RebuildRun->new(
        id_service => $self->id_service,
        indexer    => $self->indexer,
        schema     => $self->schema,
    );
};
has recorder => sub ($self) {
    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;

# 6.5: the maintenance the shell could do and the console could not. What an
# operator reads first: is search behind, and how did the last rebuild go.
sub search_status ($self) {
    return {
        lag    => $self->indexer->observe_lag,
        latest => $self->rebuild_run->latest,
    };
}

# Starts a search rebuild through the outbox (Search::RebuildRun) and audits
# who asked, in the caller's transaction.
sub request_search_rebuild ( $self, $input ) {
    my $correlation_id = $self->id_service->uuid;
    my $run            = $self->rebuild_run->request(
        {
            actor_id       => $input->{actor_user_id},
            correlation_id => $correlation_id,
            entity_type    => 'all',
        }
    );
    $self->_audit(
        {
            action         => 'admin.search_rebuild_requested',
            actor_user_id  => $input->{actor_user_id},
            correlation_id => $correlation_id,
            metadata       => { run_id => $run->{run_id}, via => 'web' },
            target_id      => $run->{run_id},
            target_type    => 'search_rebuild',
        }
    );

    return { run_id => $run->{run_id}, status => 'requested' };
}

# Drops every cached public page, in every web process (the cache's
# invalidation bus carries it), and audits who did. Nothing is lost: each
# page is rendered again on its next request.
sub purge_public_cache ( $self, $input ) {
    for my $tag (@PURGED_TAGS) {
        $self->cache->invalidate_tag($tag);
    }
    my $correlation_id = $self->id_service->uuid;
    $self->_audit(
        {
            action         => 'admin.cache_purged',
            actor_user_id  => $input->{actor_user_id},
            correlation_id => $correlation_id,
            metadata       => { tags => [@PURGED_TAGS], via => 'web' },
            target_id      => $correlation_id,
            target_type    => 'cache',
        }
    );

    return { status => 'purged', tags => [@PURGED_TAGS] };
}

sub _audit ( $self, $input ) {
    return $self->recorder->record_audit(
        action         => $input->{action},
        actor_id       => $input->{actor_user_id},
        correlation_id => $input->{correlation_id},
        created_at     => $self->clock->now_iso8601,
        metadata       => $input->{metadata},
        previous_hash  => undef,
        record_hash    => q{},
        schema_version => $SCHEMA_VERSION,
        target_id      => $input->{target_id},
        target_type    => $input->{target_type},
    );
}

1;

__END__

=head1 NAME

GPForum::Service::Admin::Maintenance - Search rebuilds, search lag and cache purges for the console.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $maintenance = GPForum::Service::Admin::Maintenance->new(
        cache  => $cache,
        schema => $schema,
    );
    my $status = $maintenance->search_status;
    $maintenance->request_search_rebuild( { actor_user_id => $admin_id } );
    $maintenance->purge_public_cache( { actor_user_id => $admin_id } );

=head1 DESCRIPTION

The console side of operations that had only a shell command (quality
program 6.5): the search index's lag and last rebuild, a rebuild run through
the outbox, and a purge of the public page cache. Each write is audited.

=head1 SUBROUTINES/METHODS

=head2 search_status

The search lag and the latest rebuild run.

=head2 request_search_rebuild

Starts a rebuild; returns its run id.

=head2 purge_public_cache

Invalidates every cached public page; returns the tags purged.

=head1 DIAGNOSTICS

Dies when the database does; the workflow's transaction rolls back.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Search::RebuildRun>,
L<GPForum::Infrastructure::EventRecorder>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
