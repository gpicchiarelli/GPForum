package GPForum::Service::Portability::ExportBundleBuilder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $FORMAT_JSON => 'json';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub create_request {
    my ( $self, $input ) = @_;

    my $request = {
        export_request_id => $self->id_service->uuid,
        requester_user_id => $input->{requester_user_id},
        subject_user_id   => $input->{subject_user_id},
        export_type       => $input->{export_type},
        format            => $input->{format} || $FORMAT_JSON,
        status            => 'pending',
        created_at        => $self->clock->now_iso8601,
        finished_at       => undef,
        manifest          => {},
    };
    $self->schema->resultset('ExportRequest')->create($request);

    return $request;
}

sub build_user_bundle {
    my ( $self, $subject_user_id, $parts ) = @_;

    return {
        subject_user_id => $subject_user_id,
        generated_at    => $self->clock->now_iso8601,
        format          => $FORMAT_JSON,
        profile         => _hash_part( $parts, 'profile' ),
        posts           => _array_part( $parts, 'posts' ),
        attachments     => _array_part( $parts, 'attachments' ),
        subscriptions   => _array_part( $parts, 'subscriptions' ),
        preferences     => _array_part( $parts, 'preferences' ),
    };
}

sub safe_manifest {
    my ( $self, $bundle ) = @_;

    return {
        subject_user_id => $bundle->{subject_user_id},
        generated_at    => $bundle->{generated_at},
        format          => $bundle->{format},
        counts          => {
            posts         => scalar @{ $bundle->{posts} },
            attachments   => scalar @{ $bundle->{attachments} },
            subscriptions => scalar @{ $bundle->{subscriptions} },
            preferences   => scalar @{ $bundle->{preferences} },
        },
    };
}

sub _array_part {
    my ( $parts, $name ) = @_;

    return $parts->{$name} || [];
}

sub _hash_part {
    my ( $parts, $name ) = @_;

    return $parts->{$name} || {};
}

1;
