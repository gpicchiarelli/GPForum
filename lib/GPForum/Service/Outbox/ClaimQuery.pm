# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Outbox::ClaimQuery;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $PENDING_STATUS => 'pending';
const my $FAILED_STATUS  => 'failed';
const my $RUNNING_STATUS => 'running';
const my $CLAIM_READY_SQL => join "\n",
  'WITH ready AS (',
  '    SELECT outbox_id, next_attempt_at, created_at',
  '      FROM outbox_messages',
  '     WHERE (',
  '               status IN (?, ?)',
  '           AND next_attempt_at <= ?::timestamptz',
  '           AND (locked_until IS NULL OR locked_until <= ?::timestamptz)',
  '           )',
  '        OR (',
  '               status = ?',
  '           AND locked_until IS NOT NULL',
  '           AND locked_until <= ?::timestamptz',
  '           )',
  '     ORDER BY next_attempt_at ASC, created_at ASC, outbox_id ASC',
  '     LIMIT ?',
  '     FOR UPDATE SKIP LOCKED',
  '),',
  'claimed AS (',
  '    UPDATE outbox_messages AS outbox',
  '       SET status = ?,',
  '           locked_at = ?::timestamptz,',
  '           locked_by = ?,',
  '           locked_until = ?::timestamptz',
  '      FROM ready',
  '     WHERE outbox.outbox_id = ready.outbox_id',
  ' RETURNING outbox.*',
  ')',
  'SELECT claimed.*',
  '  FROM claimed',
  '  JOIN ready ON ready.outbox_id = claimed.outbox_id',
' ORDER BY ready.next_attempt_at ASC, ready.created_at ASC, ready.outbox_id ASC';

sub sql {
    return $CLAIM_READY_SQL;
}

sub bind_values ( $, $input ) {
    return [
        $PENDING_STATUS,     $FAILED_STATUS,  $input->{now},
        $input->{now},       $RUNNING_STATUS, $input->{now},
        $input->{limit},     $RUNNING_STATUS, $input->{now},
        $input->{worker_id}, $input->{locked_until},
    ];
}

sub pending_status {
    return $PENDING_STATUS;
}

sub failed_status {
    return $FAILED_STATUS;
}

sub running_status {
    return $RUNNING_STATUS;
}

1;

__END__

=head1 NAME

GPForum::Service::Outbox::ClaimQuery - PostgreSQL ready-queue claim SQL.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $sql  = $query->sql;
    my $bind = $query->bind_values(\%input);

=head1 DESCRIPTION

Owns the C<FOR UPDATE SKIP LOCKED> claim statement and its bind order.
L<GPForum::Service::Outbox::Dispatcher> still opens the transaction and
executes the statement.

=head1 SUBROUTINES/METHODS

=head2 sql

Returns the claim SQL.

=head2 bind_values

Returns bind values for now, limit, worker id, and lock expiry.

=head2 pending_status

Returns the pending status token.

=head2 failed_status

Returns the failed status token.

=head2 running_status

Returns the running status token.

=head1 DIAGNOSTICS

None. Execution errors stay in the dispatcher.

=head1 CONFIGURATION AND ENVIRONMENT

Requires PostgreSQL timestamptz casts.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The SQL is PostgreSQL-specific. Resultset claiming stays on the dispatcher.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
