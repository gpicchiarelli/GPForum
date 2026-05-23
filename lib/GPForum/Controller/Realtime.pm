package GPForum::Controller::Realtime;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my $HTTP_UNAUTHORIZED => 401;

sub stream {
    my ($self) = @_;

    my $user_id = $self->session('user_id');
    return $self->render(
        text   => 'Authentication required',
        status => $HTTP_UNAUTHORIZED,
    ) if !defined $user_id || !length $user_id;

    my $connection_id = $self->gp_id->uuid;
    my $actor         = { user_id => $user_id };

    $self->gp_realtime_hub->register_connection( $connection_id, $actor,
        $self );
    $self->_send_connected($connection_id);

    $self->on(
        json => sub {
            my ( $controller, $message ) = @_;
            $controller->_handle_message( $connection_id, $actor, $message );
        }
    );
    $self->on(
        finish => sub {
            my ($controller) = @_;
            $controller->gp_realtime_hub->disconnect($connection_id);
        }
    );

    return;
}

sub _handle_message {
    my ( $self, $connection_id, $actor, $message ) = @_;

    return $self->_send_error('unknown_message')
      if !$message || ( $message->{type} || q{} ) ne 'subscribe';

    my $result = $self->gp_realtime_hub->subscribe(
        {
            connection_id => $connection_id,
            actor         => $actor,
            channel       => $message->{channel},
            context       => { transport => 'websocket' },
        }
    );

    return $self->_send_error( $result->{reason} ) if !$result->{ok};

    return $self->send(
        {
            json => {
                type    => 'subscribed',
                channel => $result->{channel},
            },
        }
    );
}

sub _send_connected {
    my ( $self, $connection_id ) = @_;

    return $self->send(
        {
            json => {
                type          => 'realtime.connected',
                connection_id => $connection_id,
                fallback      => $self->gp_realtime_hub->fallback_state,
            },
        }
    );
}

sub _send_error {
    my ( $self, $reason ) = @_;

    return $self->send(
        {
            json => {
                type   => 'error',
                reason => $reason,
            },
        }
    );
}

1;
