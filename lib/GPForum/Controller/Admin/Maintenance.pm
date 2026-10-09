# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Admin::Maintenance;

use Mojo::Base 'GPForum::Controller::Admin::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

# Neither is behind a danger confirmation: a rebuild rewrites the search
# index from the forum, and a purge drops pages that are rendered again on
# their next request. Nothing is taken away.
sub search_rebuild ($self) {
    return $self->_maintenance( 'request_search_rebuild',
        sub { return $self->admin_access->search_rebuild_status; } );
}

# The answer follows how far the purge went: a purge the shared cache did not
# take is a warning naming the tags it left, not "purged".
sub cache_purge ($self) {
    return $self->_maintenance(
        'purge_public_cache',
        sub ($stored) {
            return $self->admin_access->cache_purge_status( $stored->{status} );
        }
    );
}

sub _maintenance ( $self, $command, $status_of ) {
    my $actor_user_id = $self->authorized_write_user_id;
    if ( !$actor_user_id ) {
        return;
    }

    my $result = $self->gp_admin_workflow->$command(
        {
            actor_user_id => $actor_user_id,
            command_id    => $self->command_id_param,
        }
    );
    my $failure = $self->write_failure($result);
    return $failure if $failure;

    my $stored = $result->{stored} || {};
    return $self->maintenance_response( $status_of->($stored), $stored );
}

1;

__END__

=head1 NAME

GPForum::Controller::Admin::Maintenance - Rebuild search and purge the page cache from the console.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    POST /admin/search/rebuild
    POST /admin/cache/purge

=head1 DESCRIPTION

The console side of two operations that had only a shell command or none
(quality program 6.5). The work is L<GPForum::Service::Admin::Maintenance>'s.

=head1 SUBROUTINES/METHODS

=head2 search_rebuild

Starts a search rebuild through the outbox; redirects to the jobs page, or
answers JSON with the run id.

=head2 cache_purge

Drops every cached public page; redirects to the jobs page, or answers JSON.
The status is C<cache_purged>, or C<cache_purged_locally> when the shared
cache was not reached for some tags: the flash is then a warning naming
them, and the JSON's C<result> carries C<purged_locally> and its
C<unreached_tags>.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Controller::Admin::Base>.

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
