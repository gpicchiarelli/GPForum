# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::SecurityAudit;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Clock;
use GPForum::Service::Identity::Event;

our $VERSION = '0.001';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
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

sub record_login_request ( $self, $input ) {
    return $self->_record(
        $self->events->login_request_audit( $self->_timed($input) ) );
}

sub record_logout_request ( $self, $input ) {
    return $self->_record(
        $self->events->logout_request_audit( $self->_timed($input) ) );
}

sub _timed ( $self, $input ) {
    return { %{$input}, created_at => $self->clock->now_iso8601, };
}

sub _record ( $self, $audit ) {
    my $row = $self->recorder->record_audit( %{$audit} );

    return { ok => 1, audit => $row };
}

1;
