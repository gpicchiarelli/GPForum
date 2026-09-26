# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Outbox::Retry;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $FIRST_FAILURE_OFFSET => 1;
const my $LOCK_SECONDS         => 60;
const my $FAILED_STATUS        => 'failed';
const my $CANCELLED_STATUS     => 'cancelled';
const my $PERMANENT_FAILURE    => 'permanent';
const my $DEFAULT_MAX_ATTEMPTS => 5;

has max_attempts => $DEFAULT_MAX_ATTEMPTS;

sub next_attempt ( $, $message ) {
    my $current = $message->get_column('attempt_count') || 0;

    return $current + $FIRST_FAILURE_OFFSET;
}

sub status ( $self, $attempt_count, $failure_type = undef ) {
    if ( _is_permanent($failure_type) ) {
        return $CANCELLED_STATUS;
    }
    if ( $attempt_count >= $self->max_attempts ) {
        return $CANCELLED_STATUS;
    }

    return $FAILED_STATUS;
}

sub _is_permanent ($failure_type) {
    if ( defined $failure_type && $failure_type eq $PERMANENT_FAILURE ) {
        return 1;
    }

    return 0;
}

sub backoff_seconds ( $, $attempt_count ) {
    return $attempt_count * $LOCK_SECONDS;
}

sub lock_seconds {
    return $LOCK_SECONDS;
}

sub is_cancelled ( $, $status ) {
    return $status eq $CANCELLED_STATUS ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Service::Outbox::Retry - Outbox attempt and backoff policy.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $attempt = $retry->next_attempt($message);
    my $status  = $retry->status($attempt);
    my $done    = $retry->status( $attempt, 'permanent' );

=head1 DESCRIPTION

Owns attempt increment, cancelled-versus-failed status, lock duration, and
retry backoff. L<GPForum::Service::Outbox::Dispatcher> still updates rows and
writes dead letters.

=head1 SUBROUTINES/METHODS

=head2 next_attempt

Returns the next attempt count from the current row.

=head2 status

Returns C<cancelled> when attempts are exhausted or the failure is
C<permanent>, otherwise C<failed>.

=head2 backoff_seconds

Returns lock-seconds times the attempt count.

=head2 lock_seconds

Returns the claim lock duration in seconds.

=head2 is_cancelled

True when the status is C<cancelled>.

=head1 DIAGNOSTICS

Missing attempt counts start from zero.

=head1 CONFIGURATION AND ENVIRONMENT

C<max_attempts> defaults to 5, matching the dispatcher.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Backoff is linear on the lock quantum, not exponential.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
