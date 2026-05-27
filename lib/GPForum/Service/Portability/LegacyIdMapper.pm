package GPForum::Service::Portability::LegacyIdMapper;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub map_identifier {
    my ( $self, $input ) = @_;

    my $mapping = {
        legacy_id_map_id => $self->id_service->uuid,
        import_job_id    => $input->{import_job_id},
        legacy_type      => $input->{legacy_type},
        legacy_id        => $input->{legacy_id},
        native_type      => $input->{native_type},
        native_id        => $input->{native_id},
        canonical_url    => $input->{canonical_url},
        visibility       => $input->{visibility},
        created_at       => $self->clock->now_iso8601,
    };
    $self->schema->resultset('LegacyIdMap')->create($mapping);

    return $mapping;
}

sub find_native {
    my ( $self, $legacy_type, $legacy_id ) = @_;

    return $self->schema->resultset('LegacyIdMap')->find(
        {
            legacy_type => $legacy_type,
            legacy_id   => $legacy_id,
        }
    );
}

1;
