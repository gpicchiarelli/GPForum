# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Portability::ExportBundleBuilder;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::X::Conflict;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $FORMAT_JSON        => 'json';
const my $SCHEMA_VERSION     => 1;
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

# Each part a stored export reads: its resultset, the column naming the
# member, and the fields it keeps.
const my %EXPORT_PARTS => (
    attachments   => [ 'Attachment', 'owner_user_id', \@ATTACHMENT_FIELDS ],
    notifications =>
      [ 'NotificationInbox', 'recipient_user_id', \@NOTIFICATION_FIELDS ],
    posts       => [ 'Post', 'author_user_id',            \@POST_FIELDS ],
    preferences => [ 'NotificationPreference', 'user_id', \@PREFERENCE_FIELDS ],
    subscriptions => [ 'Subscription', 'user_id', \@SUBSCRIPTION_FIELDS ],
);

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
__PACKAGE__->requires(qw(schema));

# Post ids bound per statement when reading a member's post bodies: libpq
# refuses more than 65,535 parameters, and one bind per post of a long-time
# member of a large forum passed that, so the whole export failed.
has body_batch_size => 10_000;

sub create_request ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_create_or_reuse_request($input);
        }
    );
}

# A member has one pending export at a time: a request that finds one, or
# loses the race to insert one, answers with it. A request id that collides
# is drawn again, once.
sub _create_or_reuse_request ( $self, $input ) {
    my $existing = $self->_pending_request($input);
    return $self->_finish_leftover_export($existing) if $existing;

    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_request($input); } );
    return $created if $created;

    my $conflict = GPForum::X::Conflict->caught($error);
    if (
        !$conflict
        || !(
            $conflict->on($ID_CONSTRAINT) || $conflict->on($PENDING_CONSTRAINT)
        )
      )
    {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    $existing = $self->_pending_request($input);
    return $self->_finish_leftover_export($existing) if $existing;
    if ( $conflict->on($PENDING_CONSTRAINT) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_request($input); } );
    return $created if $created;

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _pending_request ( $self, $input ) {
    my $resultset = $self->schema->resultset('ExportRequest');
    my $search    = $resultset->search_rs(
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
        return undef;
    }

    return _request_hash($row);
}

sub _insert_request ( $self, $input ) {
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

# A pending request left by a writer that stopped before its event: the
# event and audit row are written now, once.
sub _finish_leftover_export ( $self, $existing ) {
    my $recorded = $self->recorder->event_recorded( join q{:},
        'privacy.export_requested', $existing->{export_request_id} );
    if ( !$recorded ) {
        $self->_record_event_and_audit(
            {
                action     => 'privacy.export_requested',
                actor_id   => $existing->{requester_user_id},
                created_at => $existing->{created_at}
                  || $self->clock->now_iso8601,
                idempotency => $existing->{export_request_id},
                metadata    => {},
                payload     => _request_payload($existing),
                request     => $existing,
            }
        );
    }

    return $existing;
}

sub request_user_export ( $self, $user_id ) {
    return $self->create_request(
        {
            requester_user_id => $user_id,
            subject_user_id   => $user_id,
            export_type       => 'user_data',
            format            => $FORMAT_JSON,
        }
    );
}

sub complete_user_export ( $self, $export_request_id, $parts = undef ) {
    return $self->schema->txn_do(
        sub {
            return $self->_complete_request( $export_request_id, $parts );
        }
    );
}

sub _complete_request ( $self, $export_request_id, $parts ) {
    my $request =
      $self->schema->resultset('ExportRequest')->find($export_request_id);
    if ( !$request ) {
        return undef;
    }
    if ( ( _column( $request, 'status' ) || q{} ) eq $STATUS_COMPLETED ) {
        return _request_hash($request);
    }

    my $subject_user_id = _column( $request, 'subject_user_id' );
    my $bundle =
        $parts
      ? $self->build_user_bundle( $subject_user_id, $parts )
      : $self->_build_user_bundle_from_storage($subject_user_id);
    my $summary = $self->safe_manifest($bundle);
    my $stored  = {
        %{$summary},
        map { $_ => $bundle->{$_} }
          qw(attachments notifications posts preferences profile subscriptions)
    };
    my $finished = $self->clock->now_iso8601;
    $request->update(
        {
            status      => $STATUS_COMPLETED,
            finished_at => $finished,
            manifest    => $stored,
        }
    );

    my $request_id = _column( $request, 'export_request_id' );
    $self->_record_event_and_audit(
        {
            action   => 'privacy.export_completed',
            actor_id => _column( $request, 'requester_user_id' ),
            request  => $request,
            payload  => {
                %{ _request_payload($request) }, manifest => $summary,
            },
            metadata => {
                export_request_id => $request_id,
                counts            => $summary->{counts},
            },
            created_at  => $finished,
            idempotency => $request_id . q{:completed},
        }
    );

    return {
        %{ _request_hash($request) },
        status      => $STATUS_COMPLETED,
        finished_at => $finished,
        manifest    => $stored,
    };
}

sub build_user_bundle ( $self, $subject_user_id, $parts ) {
    return {
        subject_user_id => $subject_user_id,
        generated_at    => $self->clock->now_iso8601,
        format          => $FORMAT_JSON,
        profile         => $parts->{profile}       || {},
        posts           => $parts->{posts}         || [],
        attachments     => $parts->{attachments}   || [],
        notifications   => $parts->{notifications} || [],
        subscriptions   => $parts->{subscriptions} || [],
        preferences     => $parts->{preferences}   || [],
    };
}

sub safe_manifest ( $self, $bundle ) {
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

# Every part read from storage, the posts with their bodies.
sub _build_user_bundle_from_storage ( $self, $subject_user_id ) {
    my %parts;
    for my $part ( sort keys %EXPORT_PARTS ) {
        my ( $resultset, $member_column, $fields ) = @{ $EXPORT_PARTS{$part} };
        $parts{$part} =
          $self->_search_hashes( $resultset,
            { $member_column => $subject_user_id }, $fields );
    }
    $self->_attach_post_bodies( $parts{posts} );
    $parts{profile} = $self->_safe_profile($subject_user_id);

    return $self->build_user_bundle( $subject_user_id, \%parts );
}

# The bodies are read body_batch_size posts at a time.
sub _attach_post_bodies ( $self, $posts ) {
    my @ids = map { $_->{post_id} } @{$posts};
    my %body_of;
    while ( my @batch = splice @ids, 0, $self->body_batch_size ) {
        my $bodies =
          $self->_search_hashes( 'PostBody', { post_id => { -in => \@batch } },
            \@BODY_FIELDS );
        for my $body ( @{$bodies} ) {
            $body_of{ $body->{post_id} } = $body;
        }
    }

    for my $post ( @{$posts} ) {
        my $body = $body_of{ $post->{post_id} } || {};
        $post->{body_format} = $body->{body_format};
        $post->{body_source} = $body->{body_source};
    }

    return;
}

sub _search_hashes ( $self, $name, $query, $fields ) {
    my $resultset;
    try {
        $resultset = $self->schema->resultset($name);
    }
    catch ($error) {
        return [];
    };
    if ( !$resultset ) {
        return [];
    }

    my @hashes;
    for my $row ( _rows( $resultset->search_rs($query) ) ) {
        push @hashes, { map { $_ => _column( $row, $_ ) } @{$fields} };
    }

    return \@hashes;
}

sub _safe_profile ( $self, $subject_user_id ) {
    my $user;
    try {
        $user = $self->schema->resultset('User')->find($subject_user_id);
    }
    catch ($error) {
        return {};
    };
    if ( !$user ) {
        return {};
    }

    return {
        created_at         => _column( $user, 'created_at' ),
        display_name       => _column( $user, 'display_name' ),
        email              => _column( $user, 'email_normalized' ),
        email_verified_at  => _column( $user, 'email_verified_at' ),
        preferred_locale   => _column( $user, 'preferred_locale' ),
        preferred_theme    => _column( $user, 'preferred_theme' ),
        preferred_timezone => _column( $user, 'preferred_timezone' ),
        status             => _column( $user, 'status' ),
        user_id            => _column( $user, 'id' ),
        username           => _column( $user, 'username' ),
    };
}

sub _record_event_and_audit ( $self, $input ) {
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

sub _request_payload ($request) {
    return {
        export_request_id => _column( $request, 'export_request_id' ),
        export_type       => _column( $request, 'export_type' ),
        format            => _column( $request, 'format' ),
        status            => _column( $request, 'status' ),
        subject_user_id   => _column( $request, 'subject_user_id' ),
    };
}

sub _request_hash ($request) {
    return {
        export_request_id => _column( $request, 'export_request_id' ),
        requester_user_id => _column( $request, 'requester_user_id' ),
        subject_user_id   => _column( $request, 'subject_user_id' ),
        export_type       => _column( $request, 'export_type' ),
        format            => _column( $request, 'format' ),
        status            => _column( $request, 'status' ),
        created_at        => _column( $request, 'created_at' ),
        finished_at       => _column( $request, 'finished_at' ),
        manifest          => _manifest($request) || {},
    };
}

# The manifest decoded: get_column returns the jsonb column's text, so an
# already completed export came back with its bundle as one string.
sub _manifest ($request) {
    if ( ref $request ne 'HASH' && $request->can('get_inflated_column') ) {
        return $request->get_inflated_column('manifest');
    }

    return _column( $request, 'manifest' );
}

sub _rows ($search) {
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

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

1;

__END__

=head1 NAME

GPForum::Service::Portability::ExportBundleBuilder - A member's data export: the request, the bundle and its completion.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $exports = GPForum::Service::Portability::ExportBundleBuilder->new(
        schema => $schema,
    );

    my $request = $exports->request_user_export($user_id);

    # Later, in the worker:
    my $done =
      $exports->complete_user_export( $request->{export_request_id} );
    # $done->{status} is 'completed'; $done->{manifest}{counts}{posts}

=head1 DESCRIPTION

Serves a member's right to a copy of their data. A request is an
C<export_requests> row in the C<pending> state, recorded with a
C<privacy.export_requested> event and audit entry. Asking again while one
is pending returns the pending one, and records its event first if an
earlier attempt left it out.

Completing gathers the bundle: the profile (username, display name,
normalized email, status and preferences), every post the member wrote with
its body source, their attachments' metadata, notifications, subscriptions
and notification preferences. The bundle is stored as the request's
manifest together with its counts, the request is marked C<completed>, and
a C<privacy.export_completed> event and audit entry are recorded, whose
payload carries the safe manifest: the counts, not the data. A table the
schema lacks is exported as an empty list.

Post bodies are read C<body_batch_size> post ids per statement: libpq
refuses more than 65,535 parameters, and binding one per post of a
long-time member of a large forum made the whole export fail.

=head1 SUBROUTINES/METHODS

=head2 create_request

Takes a hash reference with C<requester_user_id>, C<subject_user_id>,
C<export_type> and C<format> (default C<json>). In a transaction, returns
the request as a hash (C<export_request_id>, requester, subject, type,
format, C<status>, C<created_at>, C<finished_at>, C<manifest>): the pending
one for the same requester, subject, type and format if there is one, a new
one otherwise. A collision on the minted id is retried once; losing the race
to another pending request returns that one.

=head2 request_user_export

Takes a user id. Calls C<create_request> for the user about themselves,
type C<user_data>, format C<json>.

=head2 complete_user_export

Takes an export request id and optional bundle parts. In a transaction,
builds the bundle from the parts given or from the database, stores it and
marks the request completed. Returns the request hash with C<status>
C<completed>, C<finished_at> and the stored manifest (the safe manifest plus
the bundle's profile, posts, attachments, notifications, subscriptions and
preferences). An already completed request is returned as stored, and an
unknown id gives undef.

=head2 build_user_bundle

Takes a subject user id and a hash reference of parts. Returns the bundle:
C<subject_user_id>, C<generated_at> (now), C<format> C<json>, C<profile> (a
hash) and C<posts>, C<attachments>, C<notifications>, C<subscriptions> and
C<preferences> (array references, empty when not in the parts). Reads
nothing.

=head2 safe_manifest

Takes a bundle. Returns the summary that may travel in events:
C<subject_user_id>, C<generated_at>, C<format> and C<counts> of each list.

=head1 DIAGNOSTICS

An unknown request in C<complete_user_export> gives undef. An insert error
other than the two collisions above, or a collision whose winning request
cannot be found, is rethrown with C<croak>; other database errors propagate.
Either rolls the transaction back.

=head1 CONFIGURATION AND ENVIRONMENT

C<body_batch_size>, the post ids bound per body query (default 10,000).

=head1 DEPENDENCIES

L<GPForum::Infrastructure::Row>, L<GPForum::Infrastructure::EventRecorder>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Infrastructure::Id>,
L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
