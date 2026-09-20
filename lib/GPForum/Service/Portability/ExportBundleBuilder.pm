package GPForum::Service::Portability::ExportBundleBuilder;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $FORMAT_JSON        => 'json';
const my $SCHEMA_VERSION     => 1;
const my $ROW_LIMIT_ONE      => 1;
const my $USER_AGGREGATE     => 'user';
const my $STATUS_COMPLETED   => 'completed';
const my $ID_CONSTRAINT      => 'export_requests_pkey';
const my $PENDING_CONSTRAINT => 'idx_export_requests_pending_unique';
const my @POST_FIELDS => qw(
  post_id thread_id visibility moderation_state
  position created_at updated_at deleted_at
);
const my @ATTACHMENT_FIELDS => qw(
  attachment_id original_filename media_type byte_size
  checksum state scan_status created_at uploaded_at deleted_at
);
const my @NOTIFICATION_FIELDS => qw(
  notification_id created_at read_at
);
const my @SUBSCRIPTION_FIELDS => qw(
  subscription_id target_type target_id preference
  created_at muted_at revoked_at
);
const my @PREFERENCE_FIELDS => qw(
  channel enabled digest_frequency updated_at
);
const my @BODY_FIELDS => qw(
  post_id body_source body_format
);

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
            return $self->_create_or_reuse_request($input);
        }
    );
}

sub _create_or_reuse_request {
    my ( $self, $input ) = @_;

    my $existing = $self->_pending_request($input);
    if ($existing) {
        return $self->_finish_leftover_export($existing);
    }

    return $self->_insert_or_reuse_request($input);
}

sub _insert_or_reuse_request {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_insert_request($input); };
    if ($created) {
        return $created;
    }

    return $self->_reuse_after_conflict( $input, $EVAL_ERROR );
}

sub _reuse_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_export_after_unique( $input, $error );
}

sub _export_after_unique {
    my ( $self, $input, $error ) = @_;

    if ( _export_id_conflict($error) ) {
        return $self->_export_after_id_conflict($input);
    }
    if ( _pending_export_conflict($error) ) {
        return $self->_reuse_export_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _export_after_id_conflict {
    my ( $self, $input ) = @_;

    my $existing = $self->_pending_request($input);
    if ($existing) {
        return $self->_finish_leftover_export($existing);
    }

    return $self->_retry_export_id($input);
}

sub _retry_export_id {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_insert_request($input); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reuse_export_row {
    my ( $self, $input, $error ) = @_;

    my $existing = $self->_pending_request($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_finish_leftover_export($existing);
}

sub _export_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _pending_export_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $PENDING_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _pending_request {
    my ( $self, $input ) = @_;

    my $resultset = $self->schema->resultset('ExportRequest');
    my $search    = $resultset->search(
        {
            export_type       => $input->{export_type},
            format            => $input->{format} || $FORMAT_JSON,
            requester_user_id => $input->{requester_user_id},
            status            => 'pending',
            subject_user_id   => $input->{subject_user_id},
        },
        {
            order_by => { -desc => 'created_at' },
            rows     => 1,
        }
    );
    my $row = $search->single;
    if ( !$row ) {
        return;
    }

    return _request_hash($row);
}

sub _insert_request {
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
            return $self->_complete_request( $export_request_id, $parts );
        }
    );
}

sub _complete_request {
    my ( $self, $export_request_id, $parts ) = @_;

    my $request =
      $self->schema->resultset('ExportRequest')->find($export_request_id);
    if ( !$request ) {
        return;
    }
    if ( ( _column( $request, 'status' ) || q{} ) eq $STATUS_COMPLETED ) {
        return _request_hash($request);
    }

    return $self->_finish_request( $request, $parts );
}

sub _finish_request {
    my ( $self, $request, $parts ) = @_;

    my $bundle   = $self->_bundle_for( $request, $parts );
    my $summary  = $self->safe_manifest($bundle);
    my $stored   = _stored_manifest( $bundle, $summary );
    my $finished = $self->clock->now_iso8601;
    $request->update(
        {
            status      => $STATUS_COMPLETED,
            finished_at => $finished,
            manifest    => $stored,
        }
    );
    $self->_record_completed_export( $request, $summary, $finished );

    return {
        %{ _request_hash($request) },
        status      => $STATUS_COMPLETED,
        finished_at => $finished,
        manifest    => $stored,
    };
}

sub _bundle_for {
    my ( $self, $request, $parts ) = @_;

    my $subject_user_id = _column( $request, 'subject_user_id' );
    if ($parts) {
        return $self->build_user_bundle( $subject_user_id, $parts );
    }

    return $self->_build_user_bundle_from_storage($subject_user_id);
}

sub _record_completed_export {
    my ( $self, $request, $summary, $finished ) = @_;

    my $export_request_id = _column( $request, 'export_request_id' );
    $self->_record_event_and_audit(
        {
            action   => 'privacy.export_completed',
            actor_id => _column( $request, 'requester_user_id' ),
            request  => $request,
            payload  => {
                %{ _request_payload($request) }, manifest => $summary,
            },
            metadata => {
                export_request_id => $export_request_id,
                counts            => $summary->{counts},
            },
            created_at  => $finished,
            idempotency => $export_request_id . q{:completed},
        }
    );

    return;
}

sub _stored_manifest {
    my ( $bundle, $summary ) = @_;

    return {
        %{$summary},
        attachments   => $bundle->{attachments},
        notifications => $bundle->{notifications},
        posts         => $bundle->{posts},
        preferences   => $bundle->{preferences},
        profile       => $bundle->{profile},
        subscriptions => $bundle->{subscriptions},
    };
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

    return $self->build_user_bundle(
        $subject_user_id,
        {
            attachments   => $self->_export_attachments($subject_user_id),
            notifications => $self->_export_notifications($subject_user_id),
            posts         => $self->_export_posts($subject_user_id),
            preferences   => $self->_export_preferences($subject_user_id),
            profile       => $self->_safe_profile($subject_user_id),
            subscriptions => $self->_export_subscriptions($subject_user_id),
        }
    );
}

sub _export_posts {
    my ( $self, $user_id ) = @_;

    my $posts = $self->_search_hashes( 'Post', { author_user_id => $user_id },
        \@POST_FIELDS, );
    $self->_attach_post_bodies($posts);

    return $posts;
}

sub _attach_post_bodies {
    my ( $self, $posts ) = @_;

    my $bodies = $self->_post_bodies_by_id($posts);
    for my $post ( @{$posts} ) {
        my $body = $bodies->{ $post->{post_id} } || {};
        $post->{body_format} = $body->{body_format};
        $post->{body_source} = $body->{body_source};
    }

    return;
}

sub _post_bodies_by_id {
    my ( $self, $posts ) = @_;

    my @ids = map { $_->{post_id} } @{$posts};
    if ( !@ids ) {
        return {};
    }

    my $rows =
      $self->_search_hashes( 'PostBody', { post_id => { -in => \@ids } },
        \@BODY_FIELDS, );
    my %by_id;
    for my $row ( @{$rows} ) {
        $by_id{ $row->{post_id} } = $row;
    }

    return \%by_id;
}

sub _export_attachments {
    my ( $self, $user_id ) = @_;

    return $self->_search_hashes( 'Attachment', { owner_user_id => $user_id },
        \@ATTACHMENT_FIELDS, );
}

sub _export_notifications {
    my ( $self, $user_id ) = @_;

    return $self->_search_hashes( 'NotificationInbox',
        { recipient_user_id => $user_id },
        \@NOTIFICATION_FIELDS, );
}

sub _export_subscriptions {
    my ( $self, $user_id ) = @_;

    return $self->_search_hashes( 'Subscription', { user_id => $user_id },
        \@SUBSCRIPTION_FIELDS, );
}

sub _export_preferences {
    my ( $self, $user_id ) = @_;

    return $self->_search_hashes( 'NotificationPreference',
        { user_id => $user_id },
        \@PREFERENCE_FIELDS, );
}

sub _search_hashes {
    my ( $self, $name, $query, $fields ) = @_;

    my $resultset = eval { $self->schema->resultset($name) };
    if ( !$resultset ) {
        return [];
    }

    my @rows;
    for my $row ( _rows( $resultset->search($query) ) ) {
        push @rows, _row_hash( $row, $fields );
    }

    return \@rows;
}

sub _row_hash {
    my ( $row, $fields ) = @_;

    my %hash;
    for my $name ( @{$fields} ) {
        $hash{$name} = _column( $row, $name );
    }

    return \%hash;
}

sub _safe_profile {
    my ( $self, $subject_user_id ) = @_;

    my $user =
      eval { $self->schema->resultset('User')->find($subject_user_id) };
    if ( !$user ) {
        return {};
    }

    return {
        created_at        => _column( $user, 'created_at' ),
        display_name      => _column( $user, 'display_name' ),
        email             => _column( $user, 'email_normalized' ),
        email_verified_at => _column( $user, 'email_verified_at' ),
        preferred_locale  => _column( $user, 'preferred_locale' ),
        preferred_theme   => _column( $user, 'preferred_theme' ),
        status            => _column( $user, 'status' ),
        user_id           => _column( $user, 'id' ),
        username          => _column( $user, 'username' ),
    };
}

sub _finish_leftover_export {
    my ( $self, $existing ) = @_;

    $self->_ensure_export_write($existing);

    return $existing;
}

sub _ensure_export_write {
    my ( $self, $existing ) = @_;

    if ( $self->_export_event_exists($existing) ) {
        return;
    }

    return $self->_record_event_and_audit(
        {
            action      => 'privacy.export_requested',
            actor_id    => $existing->{requester_user_id},
            created_at  => $existing->{created_at} || $self->clock->now_iso8601,
            idempotency => $existing->{export_request_id},
            metadata    => {},
            payload     => _request_payload($existing),
            request     => $existing,
        }
    );
}

sub _export_event_exists {
    my ( $self, $existing ) = @_;

    my $search = $self->schema->resultset('EventLog')->search(
        {
            idempotency_key => join( q{:},
                'privacy.export_requested', $existing->{export_request_id} ),
        },
        { rows => $ROW_LIMIT_ONE },
    );

    if ( $search->can('single') ) {
        return $search->single;
    }

    return;
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

sub _rows {
    my ($search) = @_;

    if ( !$search ) {
        return;
    }
    if ( $search->can('all') ) {
        return $search->all;
    }
    if ( $search->can('rows') ) {
        return @{ $search->rows };
    }

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
