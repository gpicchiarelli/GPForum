package GPForum::Service::Identity::SecurityAudit;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Clock;
use GPForum::Service::Identity::Event;

our $VERSION = '0.001';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;
has events => sub { return GPForum::Service::Identity::Event->new; };

sub record_login_request {
    my ( $self, $input ) = @_;

    return $self->_record(
        $self->events->login_request_audit( $self->_timed($input) ) );
}

sub record_logout_request {
    my ( $self, $input ) = @_;

    return $self->_record(
        $self->events->logout_request_audit( $self->_timed($input) ) );
}

sub _timed {
    my ( $self, $input ) = @_;

    return { %{$input}, created_at => $self->clock->now_iso8601, };
}

sub _record {
    my ( $self, $audit ) = @_;

    my $row = $self->recorder->record_audit( %{$audit} );

    return { ok => 1, audit => $row };
}

1;
