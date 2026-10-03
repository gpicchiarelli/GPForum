# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Privacy::ErasedExports;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use JSON::MaybeXS;
use Mojo::Base -base, -signatures;

use GPForum::Service::Privacy::Record;

our $VERSION = '0.001';

const my $EXPORT_COMMAND => 'privacy.export';

has record => sub { return GPForum::Service::Privacy::Record->new; };
has schema => undef;

# An erased member's exports are copies of the data the erasure removes: the
# profile with the e-mail, every post body. The erasure anonymized the
# account and left both copies behind, in export_requests.manifest and in the
# export answer the command log keeps for a replay.
sub discard ( $self, $user_id ) {
    my @discarded = $self->_delete_bundles($user_id);
    $self->_scrub_export_answers($user_id);

    return [ sort @discarded ];
}

# The other side of the erasure: an export takes the member's account row
# FOR SHARE before it writes anything and keeps it until it commits. The
# erasure's anonymizing UPDATE needs that row, so it waits for a running
# export to commit -- and its delete, a later statement, then sees the
# bundle and discards it; an export that waited for an erasure reads the
# row again and finds the member erased. Without it, an export running while
# the erasure committed kept its bundle: the delete could not see rows the
# export had not committed yet.
sub may_export ( $self, $user_id ) {
    my $user =
      $self->schema->resultset('User')->find( $user_id, { for => 'shared' } );
    if ( !$user ) {
        return 0;
    }

    return defined $self->record->column( $user, 'deleted_at' ) ? 0 : 1;
}

sub _delete_bundles ( $self, $user_id ) {
    my $search = $self->schema->resultset('ExportRequest')
      ->search_rs( { subject_user_id => $user_id } );
    my @ids;
    for my $row ( $self->record->rows($search) ) {
        push @ids, $self->record->column( $row, 'export_request_id' );
        $row->delete;
    }

    return @ids;
}

# The command row stays, so the command id still replays and does not start
# a new export; only the bundle leaves its stored answer.
sub _scrub_export_answers ( $self, $user_id ) {
    my $search = $self->schema->resultset('CommandLog')->search_rs(
        {
            actor_id     => $user_id,
            command_type => $EXPORT_COMMAND,
        }
    );
    for my $row ( $self->record->rows($search) ) {
        $self->_scrub_answer($row);
    }

    return;
}

sub _scrub_answer ( $self, $row ) {
    my $payload = $row->get_inflated_column('payload');
    if ( !_has_bundle($payload) ) {
        return;
    }

    my %stored = %{ $payload->{response}{stored} };
    delete $stored{manifest};
    my $response = { %{ $payload->{response} }, stored => \%stored };
    $row->update(
        {
            payload       => { %{$payload}, response => $response },
            response_hash => _response_hash($response),
        }
    );

    return;
}

sub _has_bundle ($payload) {
    if ( ref $payload ne 'HASH' || ref $payload->{response} ne 'HASH' ) {
        return 0;
    }
    my $stored = $payload->{response}{stored};

    return ref $stored eq 'HASH' && exists $stored->{manifest} ? 1 : 0;
}

# As GPForum::Service::Operations::CommandIdempotency hashes the answer it
# stores, so the row's hash still describes its answer.
sub _response_hash ($response) {
    return sha256_hex(
        JSON::MaybeXS->new( canonical => 1, utf8 => 1 )->encode($response) );
}

1;

__END__

=head1 NAME

GPForum::Service::Privacy::ErasedExports - Discard an erased member's export bundles.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $discarded =
      GPForum::Service::Privacy::ErasedExports->new( schema => $schema )
      ->discard($user_id);

=head1 DESCRIPTION

A completed export stores the member's bundle -- profile with the e-mail
address, post bodies, attachment names, notifications, subscriptions and
preferences -- as the C<export_requests> row's manifest, and the export
command's answer in C<command_log> carries the same bundle for a replay.
Both are copies of the data the erasure removes.

L<GPForum::Service::Privacy::DeletionWorkflow> calls C<discard> inside the
erasure transaction, so the bundles go with the account or not at all, and
an export calls C<may_export> first, so an export that runs while the
member is erased either commits before the erasure discards it or finds the
member erased. The
evidence that they existed stays: the C<privacy.export_requested> and
C<privacy.export_completed> events and audit entries, which carry the counts
and never the data, the export command rows, and the erasure's own audit
entry, which names the requests it discarded.

=head1 SUBROUTINES/METHODS

=head2 discard

Takes a user id. Deletes every C<export_requests> row whose subject is the
member, whatever its status, and removes the bundle (C<stored.manifest>)
from the answer of each C<privacy.export> command the member sent,
recomputing the row's C<response_hash>. The rest of the answer -- status,
request id, format -- is kept, so a replay of the command id answers
without the data instead of starting a new export. Returns the deleted
request ids, sorted, as an array reference. Writes in the caller's
transaction and starts none of its own.

=head2 may_export

Takes a user id. Locks the member's C<users> row C<FOR SHARE> for the rest
of the caller's transaction and returns 1 when the member exists and is not
erased (no C<deleted_at>), 0 otherwise.
L<GPForum::Service::Privacy::Workflow> calls it before an export writes
anything: an erasure's anonymizing update of that row waits for the export
to commit, and then discards its bundle; an export that waited for an
erasure finds the member erased and writes nothing.

=head1 DIAGNOSTICS

None of its own. Database errors propagate and roll the caller's
transaction back.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Digest::SHA>, L<JSON::MaybeXS>, L<Mojo::Base> and
L<GPForum::Service::Privacy::Record>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The two sides meet on the C<users> row: an export that does not go through
C<may_export> first is not ordered against the erasure, and its bundle can
survive an erasure that commits while it runs.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
