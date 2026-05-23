package GPForum::Service::Notification::SubscriptionStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $DEFAULT_PREFERENCE => 'all';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

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

sub subscribers_for {
    my ( $self, $target_type, $target_id ) = @_;

    my $search = $self->schema->resultset('Subscription')->search(
        {
            target_type => $target_type,
            target_id   => $target_id,
            revoked_at  => undef,
            muted_at    => undef,
        }
    );

    return map { $_->get_column('user_id') }
      grep { $_->get_column('preference') ne 'none' } _rows($search);
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

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
