package GPForum::Test::NotificationPreferenceStore;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has fail        => 0;
has preferences => sub { return _default_preferences(); };
has updates     => sub { return []; };

sub preferences_for_user {
    my ( $self, $user_id ) = @_;

    die 'notification preference load failed' if $self->fail;

    return [ map { +{ %{$_}, user_id => $user_id, } } @{ $self->preferences } ];
}

sub set_preferences {
    my ( $self, $input ) = @_;

    die 'notification preference save failed' if $self->fail;

    push @{ $self->updates }, { %{$input} };
    $self->preferences(
        [
            map {
                +{
                    %{$_},
                    description_key => 'notifications.preference.'
                      . $_->{channel}
                      . '.description',
                    label_key => 'notifications.channel.' . $_->{channel},
                }
            } @{ $input->{preferences} }
        ]
    );

    return $self->preferences_for_user( $input->{user_id} );
}

sub channel_names {
    return [qw(in_app email digest)];
}

sub digest_frequency_options {
    return [
        map {
            +{
                label_key => 'notifications.digest_frequency.' . $_,
                value     => $_,
            }
        } qw(immediate daily weekly never)
    ];
}

sub _default_preferences {
    return [
        {
            channel          => 'in_app',
            description_key  => 'notifications.preference.in_app.description',
            digest_frequency => 'immediate',
            enabled          => 1,
            label_key        => 'notifications.channel.in_app',
        },
        {
            channel          => 'email',
            description_key  => 'notifications.preference.email.description',
            digest_frequency => 'daily',
            enabled          => 1,
            label_key        => 'notifications.channel.email',
        },
        {
            channel          => 'digest',
            description_key  => 'notifications.preference.digest.description',
            digest_frequency => 'daily',
            enabled          => 0,
            label_key        => 'notifications.channel.digest',
        },
    ];
}

1;
