# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::Maintenance;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

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

__PACKAGE__->requires(qw(cache));
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
has schema => undef;    # optional: only the default collaborators read it

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
#
# A tag the cache could not purge in GlifiStore (its invalidate_tag returns
# nothing: the shared layer is paused after a failure, or failed now) leaves
# the pages there current until their TTL, while every process's own copy is
# gone. The purge said "purged" all the same, and an operator who purged to
# take a page down believed it was down. It is now "purged_locally", in the
# answer and in the audit row, with the tags concerned.
sub purge_public_cache ( $self, $input ) {
    my @unreached;
    for my $tag (@PURGED_TAGS) {
        if ( !defined $self->cache->invalidate_tag($tag) ) {
            push @unreached, $tag;
        }
    }
    my $status         = @unreached ? 'purged_locally' : 'purged';
    my $correlation_id = $self->id_service->uuid;
    $self->_audit(
        {
            action         => 'admin.cache_purged',
            actor_user_id  => $input->{actor_user_id},
            correlation_id => $correlation_id,
            metadata       => {
                status         => $status,
                tags           => [@PURGED_TAGS],
                unreached_tags => [@unreached],
                via            => 'web',
            },
            target_id   => $correlation_id,
            target_type => 'cache',
        }
    );

    return {
        status         => $status,
        tags           => [@PURGED_TAGS],
        unreached_tags => [@unreached],
    };
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

Takes a hash reference with C<actor_user_id>. Invalidates every cached
public page (the tags C<forum:public-html>, C<categories> and
C<forum-index>) in this process, in the others through the cache's bus, and
in the shared cache, and records an C<admin.cache_purged> audit row.
Returns C<< { status, tags, unreached_tags } >>: C<status> is C<purged>, or
C<purged_locally> when the shared cache was not reached for one of the tags
(its C<invalidate_tag> returned C<undef>), which C<unreached_tags> lists;
the pages under those tags stay in the shared cache until their TTL. The
audit row's metadata holds the same C<status>, C<tags> and
C<unreached_tags>, and C<via> (C<web>).

=head1 DIAGNOSTICS

Dies when the database does; the workflow's transaction rolls back.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Search::RebuildRun>,
L<GPForum::Infrastructure::EventRecorder>.

Extends L<GPForum::Base>: built without C<cache> it throws
L<GPForum::X::Argument>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A purge that did not reach the shared cache is not retried: the pages it
left there expire within their TTL, and purging again once GlifiStore
answers clears them sooner.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
