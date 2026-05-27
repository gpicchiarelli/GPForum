package GPForum::Service::Notification::PreferenceStore;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Clock;

our $VERSION = '0.001';

has clock  => sub { return GPForum::Service::Clock->new; };
has schema => undef;

sub set_preference {
    my ( $self, $input ) = @_;

    my $row = {
        user_id          => $input->{user_id},
        channel          => $input->{channel},
        enabled          => $input->{enabled} ? 1 : 0,
        digest_frequency => $input->{digest_frequency},
        updated_at       => $self->clock->now_iso8601,
    };

    $self->schema->resultset('NotificationPreference')->update_or_create($row);

    return $row;
}

sub enabled_channels {
    my ( $self, $user_id ) = @_;

    my $search = $self->schema->resultset('NotificationPreference')->search(
        {
            user_id => $user_id,
            enabled => 1,
        }
    );

    return map { $_->get_column('channel') } _rows($search);
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
