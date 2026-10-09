# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Privacy::DataRightsReview;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT => 50;

__PACKAGE__->requires(qw(schema));

sub pending_deletion_requests ( $self, $options ) {
    return $self->_search(
        'DeletionRequest',
        { status => 'pending' },
        {
            order_by => [ { -asc => 'created_at' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub deletion_request ( $self, $request_id ) {
    return $self->schema->resultset('DeletionRequest')->find($request_id);
}

sub deletion_requests_for_user ( $self, $user_id, $options ) {
    return $self->_search(
        'DeletionRequest',
        {
            requester_user_id => $user_id,
            resource_type     => 'user',
            resource_id       => $user_id,
        },
        {
            order_by => [ { -desc => 'created_at' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub export_requests_for_user ( $self, $user_id, $options ) {
    return $self->_search(
        'ExportRequest',
        {
            requester_user_id => $user_id,
            subject_user_id   => $user_id,
        },
        {
            order_by => [ { -desc => 'created_at' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub completed_export_for_user ( $self, $user_id, $export_request_id ) {
    my $rows = $self->_search(
        'ExportRequest',
        {
            export_request_id => $export_request_id,
            requester_user_id => $user_id,
            status            => 'completed',
            subject_user_id   => $user_id,
        },
        { rows => 1 },
    );

    return $rows->[0];
}

sub pending_export_requests ( $self, $options ) {
    return $self->_search(
        'ExportRequest',
        { status => 'pending' },
        {
            order_by => [ { -asc => 'created_at' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub active_holds_for_user ( $self, $user_id, $options ) {
    return $self->_search(
        'RetentionHold',
        {
            resource_type => 'user',
            resource_id   => $user_id,
            ends_at       => undef,
        },
        {
            order_by => [ { -desc => 'created_at' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub active_holds ( $self, $options ) {
    return $self->_search(
        'RetentionHold',
        { ends_at => undef },
        {
            order_by => [ { -desc => 'created_at' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub erasure_jobs_by_status ( $self, $status, $options ) {
    return $self->_search(
        'ErasureJob',
        { status => $status },
        {
            order_by => [ { -asc => 'scheduled_at' } ],
            rows     => $options->{limit} || $DEFAULT_LIMIT,
        }
    );
}

sub _search ( $self, $resultset, $query, $attrs ) {
    my $search =
      $self->schema->resultset($resultset)->search_rs( $query, $attrs );

    return [ _rows($search) ];
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Privacy::DataRightsReview - Read-only queries over deletion and export requests, retention holds and erasure jobs.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $review =
      GPForum::Service::Privacy::DataRightsReview->new( schema => $schema );

    my $pending = $review->pending_deletion_requests( { limit => 20 } );
    my $exports = $review->export_requests_for_user( $user_id, {} );
    my $export =
      $review->completed_export_for_user( $user_id, $export_request_id );

=head1 DESCRIPTION

The read side of the privacy screens: the queues an administrator works
through (pending deletion and export requests, active retention holds,
erasure jobs by status) and a member's own requests. Every list is bounded,
by the C<limit> option or 50, and holds rows rather than hashes. A member's
lists are restricted to requests the member made about themselves, and
C<completed_export_for_user> checks the same, so one member cannot fetch
another's export by its id.

Each list method takes a hash reference of options of which only C<limit>
is read, and returns an array reference of rows.

=head1 SUBROUTINES/METHODS

=head2 pending_deletion_requests

Takes the options. Returns the pending deletion requests, oldest first.

=head2 deletion_request

Takes a deletion request id. Returns its row, or undef.

=head2 deletion_requests_for_user

Takes a user id and the options. Returns the deletion requests the user
made for their own account, newest first.

=head2 export_requests_for_user

Takes a user id and the options. Returns the export requests the user made
about themselves, newest first.

=head2 completed_export_for_user

Takes a user id and an export request id. Returns that export request's row
when it is completed and the user both made it and is its subject; undef
otherwise.

=head2 pending_export_requests

Takes the options. Returns the pending export requests, oldest first.

=head2 active_holds_for_user

Takes a user id and the options. Returns the retention holds on the user's
account that have no C<ends_at>, newest first.

=head2 active_holds

Takes the options. Returns every retention hold with no C<ends_at>, newest
first.

=head2 erasure_jobs_by_status

Takes a status and the options. Returns the erasure jobs in that status,
earliest C<scheduled_at> first.

=head1 DIAGNOSTICS

None of its own; database errors propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None beyond L<GPForum::Base> and L<Const::Fast>.

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
