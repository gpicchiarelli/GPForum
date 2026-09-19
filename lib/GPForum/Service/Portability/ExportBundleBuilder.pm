package GPForum::Service::Portability::ExportBundleBuilder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $FORMAT_JSON    => 'json';
const my $SCHEMA_VERSION => 1;
const my $USER_AGGREGATE => 'user';

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

sub create_request {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
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
            $self->_record_event_and_audit(
                {
                    action      => 'privacy.export_requested',
                    actor_id    => $request->{requester_user_id},
                    request     => $request,
                    payload     => _request_payload($request),
                    metadata    => {},
                    created_at  => $request->{created_at},
                    idempotency => $request->{export_request_id},
                }
            );

            return $request;
        }
    );
}

sub request_user_export {
    my ( $self, $user_id ) = @_;

    return $self->create_request(
        {
            requester_user_id => $user_id,
            subject_user_id   => $user_id,
            export_type       => 'user_data',
            format            => $FORMAT_JSON,
        }
    );
}

sub complete_user_export {
    my ( $self, $export_request_id, $parts ) = @_;

    return $self->schema->txn_do(
        sub {
            my $request =
              $self->schema->resultset('ExportRequest')
              ->find($export_request_id);
            return if !$request;

            return _request_hash($request)
              if ( _column( $request, 'status' ) || q{} ) eq 'completed';

            my $subject_user_id = _column( $request, 'subject_user_id' );
            my $bundle =
                $parts
              ? $self->build_user_bundle( $subject_user_id, $parts )
              : $self->_build_user_bundle_from_storage($subject_user_id);
            my $manifest = $self->safe_manifest($bundle);
            my $finished = $self->clock->now_iso8601;
            $request->update(
                {
                    status      => 'completed',
                    finished_at => $finished,
                    manifest    => $manifest,
                }
            );
            $self->_record_event_and_audit(
                {
                    action   => 'privacy.export_completed',
                    actor_id => _column( $request, 'requester_user_id' ),
                    request  => $request,
                    payload  => {
                        %{ _request_payload($request) },
                        manifest => $manifest,
                    },
                    metadata => {
                        export_request_id => $export_request_id,
                        counts            => $manifest->{counts},
                    },
                    created_at  => $finished,
                    idempotency => $export_request_id . q{:completed},
                }
            );

            return {
                %{ _request_hash($request) },
                status      => 'completed',
                finished_at => $finished,
                manifest    => $manifest,
            };
        }
    );
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
        notifications   => _array_part( $parts, 'notifications' ),
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
            notifications => scalar @{ $bundle->{notifications} },
            subscriptions => scalar @{ $bundle->{subscriptions} },
            preferences   => scalar @{ $bundle->{preferences} },
        },
    };
}

sub _build_user_bundle_from_storage {
    my ( $self, $subject_user_id ) = @_;

    my $profile = $self->_safe_profile($subject_user_id);

    return $self->build_user_bundle(
        $subject_user_id,
        {
            profile => $profile,
            posts   => _placeholder_rows(
                $self->_count_for(
                    'Post', { author_user_id => $subject_user_id }
                )
            ),
            attachments => _placeholder_rows(
                $self->_count_for(
                    'Attachment', { owner_user_id => $subject_user_id }
                )
            ),
            notifications => _placeholder_rows(
                $self->_count_for(
                    'NotificationInbox',
                    { recipient_user_id => $subject_user_id }
                )
            ),
            subscriptions => _placeholder_rows(
                $self->_count_for(
                    'Subscription', { user_id => $subject_user_id }
                )
            ),
            preferences => _placeholder_rows(
                $self->_count_for(
                    'NotificationPreference', { user_id => $subject_user_id }
                )
            ),
        }
    );
}

sub _safe_profile {
    my ( $self, $subject_user_id ) = @_;

    my $user = $self->schema->resultset('User')->find($subject_user_id);
    return {} if !$user;

    return {
        user_id      => _column( $user, 'id' ),
        username     => _column( $user, 'username' ),
        display_name => _column( $user, 'display_name' ),
        status       => _column( $user, 'status' ),
        created_at   => _column( $user, 'created_at' ),
    };
}

sub _count_for {
    my ( $self, $resultset_name, $query ) = @_;

    my $resultset = eval { $self->schema->resultset($resultset_name) };
    return 0 if !$resultset;

    my $search = $resultset->search($query);
    return $search->count if $search && $search->can('count');

    my @rows = _rows($search);
    return scalar @rows;
}

sub _record_event_and_audit {
    my ( $self, $input ) = @_;

    my $request        = $input->{request};
    my $correlation_id = $self->id_service->uuid;
    $self->recorder->record_event(
        event_type        => $input->{action},
        aggregate_type    => $USER_AGGREGATE,
        aggregate_id      => _column( $request, 'subject_user_id' ),
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $input->{actor_id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   =>
          join( q{:}, $input->{action}, $input->{idempotency} ),
        payload   => $input->{payload} || {},
        timestamp => $input->{created_at},
    );

    $self->recorder->record_audit(
        action         => $input->{action},
        schema_version => $SCHEMA_VERSION,
        actor_id       => $input->{actor_id},
        target_type    => $USER_AGGREGATE,
        target_id      => _column( $request, 'subject_user_id' ),
        correlation_id => $correlation_id,
        previous_hash  => undef,
        record_hash    => q{},
        metadata       => {
            export_request_id => _column( $request, 'export_request_id' ),
            %{ $input->{metadata} || {} },
        },
        created_at => $input->{created_at},
    );

    return;
}

sub _request_payload {
    my ($request) = @_;

    return {
        export_request_id => _column( $request, 'export_request_id' ),
        export_type       => _column( $request, 'export_type' ),
        format            => _column( $request, 'format' ),
        status            => _column( $request, 'status' ),
        subject_user_id   => _column( $request, 'subject_user_id' ),
    };
}

sub _request_hash {
    my ($request) = @_;

    return {
        export_request_id => _column( $request, 'export_request_id' ),
        requester_user_id => _column( $request, 'requester_user_id' ),
        subject_user_id   => _column( $request, 'subject_user_id' ),
        export_type       => _column( $request, 'export_type' ),
        format            => _column( $request, 'format' ),
        status            => _column( $request, 'status' ),
        created_at        => _column( $request, 'created_at' ),
        finished_at       => _column( $request, 'finished_at' ),
        manifest          => _column( $request, 'manifest' ) || {},
    };
}

sub _placeholder_rows {
    my ($count) = @_;

    my @rows;
    for my $index ( 1 .. $count ) {
        push @rows, { index => $index };
    }

    return \@rows;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search && $search->can('all');
    return @{ $search->rows } if $search && $search->can('rows');

    return;
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    return;
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
