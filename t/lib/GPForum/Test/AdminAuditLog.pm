# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::AdminAuditLog;

use strict;
use warnings;

use JSON::MaybeXS;
use Mojo::Base -base;

our $VERSION = '0.001';

my $CODEC = JSON::MaybeXS->new( canonical => 1, utf8 => 0 );

# The audit log as Admin::Diagnostics sees it: record_audit, EventRecorder's,
# appends a row, and page, AuditReview's, reads rows back newest first by
# action -- so a test follows a check from its audit write to the settings
# page that shows it. The metadata goes through JSON, as it does into a
# jsonb column, so a value the database could not store fails here too.
has rows => sub { return []; };

sub record_audit {
    my ( $self, %row ) = @_;

    my $stored = {
        %row,
        audit_id => 'audit-' . ( 1 + scalar @{ $self->rows } ),
        metadata => $CODEC->decode( $CODEC->encode( $row{metadata} // {} ) ),
    };
    push @{ $self->rows }, $stored;

    return { %{$stored} };
}

sub page {
    my ( $self, $filters, $page ) = @_;

    my $action = $filters->{action};
    my @rows   = reverse grep { !defined $action || $_->{action} eq $action }
      @{ $self->rows };
    my $limit = $page->{limit} || scalar @rows;
    if ( @rows > $limit ) {
        splice @rows, $limit;
    }

    return {
        next_cursor => undef,
        rows        => [ map { +{ %{$_} } } @rows ],
    };
}

# The rows for one action, oldest first.
sub actions {
    my ( $self, $action ) = @_;

    return [ grep { $_->{action} eq $action } @{ $self->rows } ];
}

1;

__END__

=head1 NAME

GPForum::Test::AdminAuditLog - Recording audit log for the console diagnostics.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $log = GPForum::Test::AdminAuditLog->new;
    GPForum::Service::Admin::Diagnostics->new(
        audit_review => $log,
        recorder     => $log,
        ...
    );

=head1 DESCRIPTION

Stands in for both L<GPForum::Infrastructure::EventRecorder> (C<record_audit>)
and L<GPForum::Service::Admin::AuditReview> (C<page>, filtered by action,
newest first), so the row a check writes is the row the page reads.

=head1 SUBROUTINES/METHODS

=head2 record_audit

Stores the row, its metadata round-tripped through JSON.

=head2 page

The rows matching C<action>, newest first, up to C<limit>.

=head2 actions

The stored rows for one action, oldest first.

=head1 DIAGNOSTICS

Dies when metadata cannot be encoded, as a jsonb insert would fail.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<JSON::MaybeXS>, L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

No hash chain, cursor or date filter.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
