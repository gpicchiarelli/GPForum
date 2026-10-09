# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::RateLimiter::LocalMemoryStore;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT          => 60;
const my $DEFAULT_WINDOW_SECONDS => 60;

has buckets => sub { return {}; };
has clock   => sub { return GPForum::Service::Clock->new; };

sub check ( $self, $input ) {
    my $key            = _key($input);
    my $limit          = $input->{limit}          || $DEFAULT_LIMIT;
    my $window_seconds = $input->{window_seconds} || $DEFAULT_WINDOW_SECONDS;
    my $now            = $self->clock->now_epoch;
    my $bucket         = $self->_bucket( $key, $now, $window_seconds );

    $bucket->{count} += 1;

    return {
        ok              => $bucket->{count} <= $limit ? 1 : 0,
        key             => $key,
        limit           => $limit,
        remaining       => _remaining( $limit, $bucket->{count} ),
        reset_at_epoch  => $bucket->{reset_at_epoch},
        store           => 'local_memory',
        window_seconds  => $window_seconds,
        observed_count  => $bucket->{count},
        mitigation_hint => 'slow_down',
    };
}

sub snapshot ($self) {
    return {
        buckets => scalar keys %{ $self->buckets },
        store   => 'local_memory',
        status  => 'ok',
    };
}

sub _bucket ( $self, $key, $now, $window_seconds ) {
    my $bucket = $self->buckets->{$key};
    if ( !$bucket || $now >= $bucket->{reset_at_epoch} ) {
        $bucket = {
            count          => 0,
            reset_at_epoch => $now + $window_seconds,
        };
        $self->buckets->{$key} = $bucket;
    }

    return $bucket;
}

sub _key ($input) {
    return join q{:}, $input->{scope}, $input->{actor_id}, $input->{action};
}

sub _remaining ( $limit, $count ) {
    my $remaining = $limit - $count;

    return $remaining > 0 ? $remaining : 0;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::RateLimiter::LocalMemoryStore - Fixed-window rate-limit counters held in this process's memory.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Operations::RateLimiter::LocalMemoryStore->new(
        clock => $clock,
    );
    my $decision = $store->check(
        {
            scope          => 'forum_http',
            actor_id       => $user_id,
            action         => 'attachment_upload',
            limit          => 10,
            window_seconds => 60,
        }
    );
    return $too_many if !$decision->{ok};

=head1 DESCRIPTION

The store L<GPForum::Service::Operations::RateLimiter> falls back to when it
has no primary store, or when the primary store fails and the degradation
policy does not fail closed. It counts in a hash, so its counts are per
process: each worker limits on its own, and a restart forgets them.

A bucket is keyed by C<scope:actor_id:action>. The first check opens a
window of C<window_seconds> from the clock's current epoch; every check in
that window adds one to the count; the first check at or after the window's
end starts a new one at zero. Buckets stay in memory until the process
ends; an expired one is reset only when its key is checked again.

=head1 SUBROUTINES/METHODS

=head2 check

Takes a hash reference with C<scope>, C<actor_id> and C<action>, which make
the bucket key, and optionally C<limit> (default 60) and C<window_seconds>
(default 60); a false value takes the default. Counts this check and
returns a hash reference with C<ok> (1 while the count is within the
limit, 0 past it), C<key>, C<limit>, C<remaining> (never below 0),
C<reset_at_epoch>, C<window_seconds>, C<observed_count>, C<store>
(C<local_memory>) and C<mitigation_hint> (C<slow_down>).

=head2 snapshot

Returns a hash reference with C<buckets> (how many keys are held),
C<store> (C<local_memory>) and C<status> (C<ok>).

=head1 DIAGNOSTICS

None: it neither croaks nor reports a failure. An undefined key part makes
Perl warn about an uninitialized value in the join.

=head1 CONFIGURATION AND ENVIRONMENT

None. The C<clock> attribute defaults to a L<GPForum::Service::Clock>; tests
pass a fixed one.

=head1 DEPENDENCIES

L<GPForum::Service::Clock>.

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
