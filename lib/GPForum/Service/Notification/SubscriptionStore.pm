# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Notification::SubscriptionStore;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::PreparedQuery;
use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $DEFAULT_PREFERENCE => 'all';
const my $ID_CONSTRAINT      => 'subscriptions_pkey';
const my $TARGET_CONSTRAINT  => 'subscriptions_unique_target';

has clock      => sub { return GPForum::Service::Clock->new; };
has prepared   => sub { return GPForum::Infrastructure::PreparedQuery->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
__PACKAGE__->requires(qw(schema));

# The member's subscription to the target, revoked or not, is restored rather
# than doubled -- whether it was there before or a concurrent save won the
# target key. A minted id already stored with no such subscription is
# minted once more.
sub save_subscription ( $self, $input ) {
    my $find = sub {
        return $self->find_for_user_target( $input->{user_id},
            $input->{target_type}, $input->{target_id}, );
    };
    my $existing = $find->();
    if ($existing) {
        return $self->_restore_subscription( $existing, $input );
    }

    my $create = sub { return $self->subscribe($input); };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $create );
    if ($created) {
        return $created;
    }

    my $conflict = GPForum::X::Conflict->caught($error);
    my $id_taken = $conflict && $conflict->on($ID_CONSTRAINT);
    if ( $id_taken || ( $conflict && $conflict->on($TARGET_CONSTRAINT) ) ) {
        $existing = $find->();
        if ($existing) {
            return $self->_restore_subscription( $existing, $input );
        }
    }
    if ( !$id_taken ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $create );
    if ($created) {
        return $created;
    }
    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub subscribe ( $self, $input ) {
    my $row = {
        subscription_id => $self->id_service->uuid,
        user_id         => $input->{user_id},
        target_type     => $input->{target_type},
        target_id       => $input->{target_id},
        preference      => $input->{preference} || $DEFAULT_PREFERENCE,
        created_at      => $self->clock->now_iso8601,
        muted_at        => undef,
        revoked_at      => undef,
    };

    $self->schema->resultset('Subscription')->create($row);

    return $row;
}

# The row by its key, through a statement built once: every signed-in
# thread page asks for one.
sub find_for_user_target ( $self, $user_id, $target_type, $target_id ) {
    my $rows = $self->schema->resultset('Subscription');
    my %key  = (
        target_id   => $target_id,
        target_type => $target_type,
        user_id     => $user_id,
    );

    return $self->prepared->row(
        schema    => $self->schema,
        shape     => 'subscription:by-key',
        source    => 'Subscription',
        resultset => sub {
            return $rows->search_rs(
                { map { ( "me.$_" => $key{$_} ) } sort keys %key } );
        },
        fallback => sub { return [ $rows->find( \%key ) // () ]; },
        values   => { map { ( "me.$_" => $key{$_} ) } keys %key },
    );
}

sub status_for_user_target ( $self, $user_id, $target_type, $target_id ) {
    return { subscribed => 0, muted => 0 } if !$user_id;

    my $subscription =
      $self->find_for_user_target( $user_id, $target_type, $target_id );

    return { subscribed => 0, muted => 0 } if !$subscription;

    my $revoked_at = _column( $subscription, 'revoked_at' );
    return { subscribed => 0, muted => 0 } if defined $revoked_at;

    return {
        subscribed      => 1,
        muted           => defined _column( $subscription, 'muted_at' ) ? 1 : 0,
        subscription_id => _column( $subscription, 'subscription_id' ),
        preference      => _column( $subscription, 'preference' ),
    };
}

sub mute ( $self, $subscription_id ) {
    return $self->_stamp_by_id( $subscription_id, 'muted_at' );
}

sub revoke ( $self, $subscription_id ) {
    return $self->_stamp_by_id( $subscription_id, 'revoked_at' );
}

sub mute_for_user_target ( $self, $input ) {
    return $self->_stamp_user_target( $input, 'muted_at' );
}

sub revoke_for_user_target ( $self, $input ) {
    return $self->_stamp_user_target( $input, 'revoked_at' );
}

sub subscribers_for ( $self, $target_type, $target_id, $options = undef ) {
    my $search = $self->schema->resultset('Subscription')->search_rs(
        {
            target_type => $target_type,
            target_id   => $target_id,
            revoked_at  => undef,
            muted_at    => undef,
        },

        # The two columns the fan-out reads, not whole subscription rows.
        { columns => [qw(user_id preference)] }
    );

    return map { $_->get_column('user_id') }
      grep { _preference_allows( $_->get_column('preference'), $options ) }
      _rows($search);
}

sub _stamp_user_target ( $self, $input, $column ) {
    my $subscription =
      $self->find_for_user_target( $input->{user_id}, $input->{target_type},
        $input->{target_id}, );

    if ( !$subscription ) {
        return { ok => 0, error => 'not_found' };
    }

    return $self->_stamp_column( $subscription, $column );
}

sub _stamp_by_id ( $self, $subscription_id, $column ) {
    my $subscription =
      $self->schema->resultset('Subscription')->find($subscription_id);

    return $self->_stamp_column( $subscription, $column );
}

sub _stamp_column ( $self, $subscription, $column ) {
    my $existing = _column( $subscription, $column );
    if ( defined $existing ) {
        return {
            ok              => 1,
            skipped         => 1,
            subscription_id => _column( $subscription, 'subscription_id' ),
            $column         => $existing,
        };
    }

    my $stamped = $self->clock->now_iso8601;
    $subscription->update( { $column => $stamped } );

    return {
        ok              => 1,
        subscription_id => _column( $subscription, 'subscription_id' ),
        $column         => $stamped,
    };
}

sub _restore_subscription ( $self, $subscription, $input ) {
    my $preference = $input->{preference} || $DEFAULT_PREFERENCE;
    my $skipped    = _subscription_already_active( $subscription, $preference );
    if ( !$skipped ) {
        $subscription->update(
            {
                muted_at   => undef,
                preference => $preference,
                revoked_at => undef,
            }
        );
    }

    my $result = {
        created_at      => _column( $subscription, 'created_at' ),
        muted_at        => undef,
        preference      => $preference,
        subscription_id => _column( $subscription, 'subscription_id' ),
        target_id       => $input->{target_id},
        target_type     => $input->{target_type},
        user_id         => $input->{user_id},
        revoked_at      => undef,
    };
    if ($skipped) {
        $result->{skipped} = 1;
    }

    return $result;
}

sub _subscription_already_active ( $subscription, $preference ) {
    if ( defined _column( $subscription, 'muted_at' ) ) {
        return 0;
    }
    if ( defined _column( $subscription, 'revoked_at' ) ) {
        return 0;
    }
    if ( ( _column( $subscription, 'preference' ) || q{} ) ne $preference ) {
        return 0;
    }

    return 1;
}

sub _preference_allows ( $preference, $options ) {
    return 0 if ( $preference || q{} ) eq 'none';
    return 1 if ( $preference || q{} ) eq 'all';

    my $notification_type = $options ? $options->{notification_type} : undef;
    return $notification_type && $notification_type eq 'mention' ? 1 : 0;
}

sub _column ( $row, $column ) {
    return GPForum::Infrastructure::Row->column( $row, $column );
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Notification::SubscriptionStore - Saves, mutes and revokes a member's subscriptions and lists a target's subscribers.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Notification::SubscriptionStore->new(
        schema => $schema,
    );
    my $saved = $store->save_subscription(
        {
            user_id     => $user_id,
            target_type => 'thread',
            target_id   => $thread_id,
            preference  => 'mentions',
        }
    );
    my $status = $store->status_for_user_target( $user_id, 'thread', $thread_id );
    $store->mute_for_user_target(
        { user_id => $user_id, target_type => 'thread', target_id => $thread_id } );
    my @user_ids = $store->subscribers_for( 'thread', $thread_id,
        { notification_type => 'reply' } );

=head1 DESCRIPTION

A member has at most one C<subscriptions> row per target
(C<subscriptions_unique_target>). Muting stamps C<muted_at> and revoking
(unsubscribing) stamps C<revoked_at>; neither deletes the row, and saving
the subscription again clears both and sets the new C<preference> on the
same row. Saving a subscription that is already active with the same
preference writes nothing and is reported as C<skipped>.

The C<preference> is C<all> (the default), C<mentions> or C<none>, as the
table's check constraint allows. C<subscribers_for> honours it: C<all>
receives everything, C<none> nothing, and any other value only
notifications of type C<mention>.

A new subscription is inserted inside a savepoint. If the insert loses a
race on the member's target, the row the other request inserted is
restored instead. If it collides on the subscription id
(C<subscriptions_pkey>), the target is looked up again and, when there is
still no row, the insert is retried once with a fresh id.

=head1 SUBROUTINES/METHODS

=head2 save_subscription

Takes a hash reference with C<user_id>, C<target_type>, C<target_id> and an
optional C<preference> (C<all> when omitted). Creates the subscription, or
restores the member's existing one for that target. Returns a hash
reference with C<subscription_id>, C<user_id>, C<target_type>,
C<target_id>, C<preference>, C<created_at>, and C<muted_at> and
C<revoked_at> (both undef), plus C<< skipped => 1 >> when the subscription
was already active with that preference.

=head2 subscribe

Takes the same hash reference and inserts a new row with a fresh uuid and
the clock's time, with no check for an existing one. Returns the inserted
fields as a hash reference. Used by C<save_subscription>; a unique conflict
propagates from here.

=head2 find_for_user_target

Takes a user id, a target type and a target id. Returns that member's
C<Subscription> row for the target, whatever its state, or undef.

=head2 status_for_user_target

Takes a user id, a target type and a target id. Returns
C<< { subscribed => 0, muted => 0 } >> when there is no user id, no row or
a revoked one; otherwise C<< subscribed => 1 >>, C<muted> (1 when
C<muted_at> is set), C<subscription_id> and C<preference>.

=head2 mute

Takes a subscription id and stamps its C<muted_at> with the clock's time.
Returns C<< { ok => 1, subscription_id, muted_at } >>, with
C<< skipped => 1 >> and the earlier C<muted_at> when it was already muted.

=head2 revoke

Takes a subscription id and stamps its C<revoked_at>, returning
C<< { ok => 1, subscription_id, revoked_at } >> as C<mute> does, with
C<< skipped => 1 >> when it was already revoked.

=head2 mute_for_user_target

Takes a hash reference with C<user_id>, C<target_type> and C<target_id>.
Returns C<< { ok => 0, error => 'not_found' } >> when the member has no
subscription to the target; otherwise the result of C<mute> for that row.

=head2 revoke_for_user_target

Takes the same hash reference. Returns
C<< { ok => 0, error => 'not_found' } >> when the member has no
subscription to the target; otherwise the result of C<revoke> for that
row.

=head2 subscribers_for

Takes a target type, a target id and an optional hash reference with
C<notification_type>. Returns the list (not a reference) of user ids
subscribed to the target, neither muted nor revoked, whose preference
allows that notification type. Without a C<notification_type> only
C<all> subscribers are listed.

=head1 DIAGNOSTICS

C<save_subscription> croaks with the database error when the insert fails
for any reason other than a unique conflict, when a target conflict leaves
no row to restore, and when the retry after an id collision fails too.
C<mute> and C<revoke> die when no subscription has the given id, calling
C<update> on undef. Other database errors propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None. C<clock> and C<id_service> default to L<GPForum::Service::Clock> and
L<GPForum::Infrastructure::Id>; tests pass fixed ones.

=head1 DEPENDENCIES

L<Const::Fast>, L<GPForum::Base>, L<GPForum::Infrastructure::Id>,
L<GPForum::Infrastructure::Row>, L<GPForum::Infrastructure::UniqueConflict>,
L<GPForum::X::Conflict>, L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The preference is not validated here; a value outside the check
constraint fails at the database.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
