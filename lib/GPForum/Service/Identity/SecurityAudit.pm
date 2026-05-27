package GPForum::Service::Identity::SecurityAudit;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub record_login_request {
    my ( $self, $input ) = @_;

    return $self->_record(
        {
            action      => 'identity.login.requested',
            actor_id    => $input->{actor_id},
            target_type => 'identity',
            target_id   => undef,
            metadata    => {
                identifier_hash      => _hash_value( $input->{identifier} ),
                outcome              => $input->{outcome} || 'accepted',
                request_address_hash =>
                  _hash_value( $input->{request_address} ),
            },
        }
    );
}

sub record_logout_request {
    my ( $self, $input ) = @_;

    return $self->_record(
        {
            action      => 'identity.logout.requested',
            actor_id    => $input->{actor_id},
            target_type => 'session',
            target_id   => undef,
            metadata    => {
                request_address_hash =>
                  _hash_value( $input->{request_address} ),
            },
        }
    );
}

sub _record {
    my ( $self, $input ) = @_;

    my $row = {
        action         => $input->{action},
        actor_id       => $input->{actor_id},
        audit_id       => $self->id_service->uuid,
        correlation_id => $self->id_service->uuid,
        created_at     => $self->clock->now_iso8601,
        metadata       => $input->{metadata},
        previous_hash  => undef,
        record_hash    => q{},
        schema_version => $SCHEMA_VERSION,
        target_id      => $input->{target_id},
        target_type    => $input->{target_type},
    };

    $self->schema->resultset('AuditLog')->create($row);

    return { ok => 1, audit => $row };
}

sub _hash_value {
    my ($value) = @_;

    return if !defined $value || !length $value;

    return sha256_hex($value);
}

1;
