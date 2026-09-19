package GPForum::Service::Notification::SubscriptionStore;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $DEFAULT_PREFERENCE => 'all';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub save_subscription {
    my ( $self, $input ) = @_;

    my $existing =
      $self->find_for_user_target( $input->{user_id}, $input->{target_type},
        $input->{target_id}, );

    if ($existing) {
        return $self->_restore_subscription( $existing, $input );
    }

    return $self->_insert_or_restore($input);
}

sub _insert_or_restore {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->subscribe($input); };
    my $error   = $EVAL_ERROR;
    if ($created) {
        return $created;
    }

    return $self->_restore_after_conflict( $input, $error );
}

sub _restore_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $existing =
      $self->find_for_user_target( $input->{user_id}, $input->{target_type},
        $input->{target_id}, );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_restore_subscription( $existing, $input );
}

sub subscribe {
    my ( $self, $input ) = @_;

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

sub find_for_user_target {
    my ( $self, $user_id, $target_type, $target_id ) = @_;

    return $self->schema->resultset('Subscription')->find(
        {
            user_id     => $user_id,
            target_type => $target_type,
            target_id   => $target_id,
        }
    );
}

sub status_for_user_target {
    my ( $self, $user_id, $target_type, $target_id ) = @_;

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

sub mute {
    my ( $self, $subscription_id ) = @_;

    return $self->_update_subscription( $subscription_id,
        { muted_at => $self->clock->now_iso8601 } );
}

sub revoke {
    my ( $self, $subscription_id ) = @_;

    return $self->_update_subscription( $subscription_id,
        { revoked_at => $self->clock->now_iso8601 } );
}

sub mute_for_user_target {
    my ( $self, $input ) = @_;

    my $subscription =
      $self->find_for_user_target( $input->{user_id}, $input->{target_type},
        $input->{target_id}, );

    return { ok => 0, error => 'not_found' } if !$subscription;

    my $changes = { muted_at => $self->clock->now_iso8601 };
    $subscription->update($changes);

    return {
        ok              => 1,
        subscription_id => _column( $subscription, 'subscription_id' ),
        %{$changes},
    };
}

sub revoke_for_user_target {
    my ( $self, $input ) = @_;

    my $subscription =
      $self->find_for_user_target( $input->{user_id}, $input->{target_type},
        $input->{target_id}, );

    return { ok => 0, error => 'not_found' } if !$subscription;

    my $changes = { revoked_at => $self->clock->now_iso8601 };
    $subscription->update($changes);

    return {
        ok              => 1,
        subscription_id => _column( $subscription, 'subscription_id' ),
        %{$changes},
    };
}

sub subscribers_for {
    my ( $self, $target_type, $target_id, $options ) = @_;

    my $search = $self->schema->resultset('Subscription')->search(
        {
            target_type => $target_type,
            target_id   => $target_id,
            revoked_at  => undef,
            muted_at    => undef,
        }
    );

    return map { $_->get_column('user_id') }
      grep { _preference_allows( $_->get_column('preference'), $options ) }
      _rows($search);
}

sub _update_subscription {
    my ( $self, $subscription_id, $changes ) = @_;

    my $subscription =
      $self->schema->resultset('Subscription')->find($subscription_id);
    $subscription->update($changes);

    return {
        subscription_id => $subscription_id,
        %{$changes},
    };
}

sub _restore_subscription {
    my ( $self, $subscription, $input ) = @_;

    my $changes = {
        preference => $input->{preference} || $DEFAULT_PREFERENCE,
        muted_at   => undef,
        revoked_at => undef,
    };
    $subscription->update($changes);

    return {
        subscription_id => _column( $subscription, 'subscription_id' ),
        user_id         => $input->{user_id},
        target_type     => $input->{target_type},
        target_id       => $input->{target_id},
        preference      => $changes->{preference},
        created_at      => _column( $subscription, 'created_at' ),
        muted_at        => undef,
        revoked_at      => undef,
    };
}

sub _preference_allows {
    my ( $preference, $options ) = @_;

    return 0 if ( $preference || q{} ) eq 'none';
    return 1 if ( $preference || q{} ) eq 'all';

    my $notification_type = $options ? $options->{notification_type} : undef;
    return $notification_type && $notification_type eq 'mention' ? 1 : 0;
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row && $row->can('get_column');

    return;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
