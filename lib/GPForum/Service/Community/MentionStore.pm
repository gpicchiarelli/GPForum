# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Community::MentionStore;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Community::MentionExtractor;

our $VERSION = '0.001';

const my $DEFAULT_MAX_MENTIONS => 10;
const my $SCHEMA_VERSION       => 1;
const my $ID_CONSTRAINT        => 'mentions_pkey';
const my $SOURCE_CONSTRAINT    => 'mentions_source_user_key';

has clock => sub { return GPForum::Service::Clock->new; };
has extractor =>
  sub { return GPForum::Service::Community::MentionExtractor->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has notification_dispatcher => undef;

# ADR 0102: who may read the source. A mention of someone who cannot is not
# recorded, so it neither notifies them nor lists the thread on their
# mentions page.
has readability => undef;
has recorder    => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;

sub record_for_source ( $self, $input ) {
    my $mentions = $self->extractor->extract( $input->{body_source} );
    return _empty_result() if !@{$mentions};

    my $limited = $self->_limit_mentions( $input, $mentions );
    $mentions = $limited->{mentions};
    my $resolved = $self->_resolve_users($mentions);
    my $work     = sub {
        my $result = $self->_insert_mentions( $input, $mentions, $resolved );
        push @{ $result->{skipped} }, @{ $limited->{skipped} };
        return $result;
    };

    return $self->schema->can('txn_do')
      ? $self->schema->txn_do($work)
      : $work->();
}

sub _limit_mentions ( $self, $input, $mentions ) {
    my $max_mentions = $input->{max_mentions} || $DEFAULT_MAX_MENTIONS;
    return { mentions => $mentions, skipped => [] }
      if @{$mentions} <= $max_mentions;

    my @allowed = @{$mentions}[ 0 .. $max_mentions - 1 ];
    my @blocked = @{$mentions}[ $max_mentions .. $#{$mentions} ];
    my @skipped = map { _skip( $_, 'fanout_limited' ) } @blocked;
    $self->_record_fanout_audit( $input, scalar @blocked, $max_mentions );

    return { mentions => \@allowed, skipped => \@skipped };
}

sub _record_fanout_audit ( $self, $input, $blocked_count, $max_mentions ) {
    my $created = eval {
        return $self->recorder->record_audit(
            action     => 'mention.fanout_limited',
            actor_id   => _uuid_or_undef( $input->{actor_id} ),
            created_at => $self->clock->now_iso8601,
            metadata   => {
                blocked_count => $blocked_count,
                max_mentions  => $max_mentions,
                source_id     => $input->{source_id},
                source_type   => $input->{source_type},
            },
            previous_hash  => undef,
            record_hash    => q{},
            schema_version => $SCHEMA_VERSION,
            target_id      => _uuid_or_undef( $input->{source_id} ),
            target_type    => 'mention',
        );
    };

    return $created;
}

sub _insert_mentions ( $self, $input, $mentions, $resolved ) {
    my $ctx = {
        created       => [],
        input         => $input,
        notifications => [],
        resolved      => $resolved,
        skipped       => [],
    };
    for my $mention ( @{$mentions} ) {
        $self->_record_mention( $mention, $ctx );
    }

    my @notifications = @{ $ctx->{notifications} };
    push @notifications, $self->_notify_mentions( $input, $ctx->{created} );

    return {
        ok            => 1,
        created       => $ctx->{created},
        notifications => \@notifications,
        skipped       => $ctx->{skipped},
    };
}

sub _record_mention ( $self, $mention, $ctx ) {
    my $user = $ctx->{resolved}{ $mention->{username} };
    if ( !$user ) {
        push @{ $ctx->{skipped} }, _skip( $mention, 'unknown_user' );
        my $undefined;
        return $undefined;
    }

    $ctx->{user} = $user;

    return $self->_record_resolved( $mention, $ctx );
}

sub _record_resolved ( $self, $mention, $ctx ) {
    my $mentioned_user_id = _column( $ctx->{user}, 'id' );
    if ( $mentioned_user_id eq $ctx->{input}{actor_id} ) {
        push @{ $ctx->{skipped} }, _skip( $mention, 'self_mention' );
        my $undefined;
        return $undefined;
    }
    if ( !$self->_source_readable( $mentioned_user_id, $ctx->{input} ) ) {
        push @{ $ctx->{skipped} }, _skip( $mention, 'source_not_readable' );
        my $undefined;
        return $undefined;
    }

    return $self->_insert_or_reuse_mention( $mention, $ctx );
}

sub _source_readable ( $self, $user_id, $input ) {
    return 1 if !$self->readability;

    return $self->readability->readable_by( $user_id, $input->{source_type},
        $input->{source_id} );
}

sub _insert_or_reuse_mention ( $self, $mention, $ctx ) {
    my $row = $self->_mention_row( $mention, $ctx );
    if ( $self->_existing_mention($row) ) {
        $self->_capture_mention_notification( $row, $ctx );
        my $undefined;
        return $undefined;
    }

    return $self->_create_or_reuse_mention( $row, $ctx );
}

sub _create_or_reuse_mention ( $self, $row, $ctx ) {
    my $undefined;

    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_mention($row); },
      );
    if ($created) {
        push @{ $ctx->{created} }, $created;
        return $undefined;
    }

    my $recovered = $self->_mention_after_conflict( $row, $error );
    if ($recovered) {
        push @{ $ctx->{created} }, $recovered;
        return $undefined;
    }

    $self->_capture_mention_notification( $row, $ctx );
    return $undefined;
}

sub _create_mention ( $self, $row ) {
    $self->schema->resultset('Mention')->create($row);

    return $row;
}

sub _mention_row ( $self, $mention, $ctx ) {
    return {
        actor_id           => $ctx->{input}{actor_id},
        created_at         => $self->clock->now_iso8601,
        mention_id         => $self->id_service->uuid,
        mentioned_user_id  => _column( $ctx->{user}, 'id' ),
        mentioned_username => $mention->{username},
        source_id          => $ctx->{input}{source_id},
        source_type        => $ctx->{input}{source_type},
    };
}

sub _mention_after_conflict ( $self, $row, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_mention_after_unique( $row, $error );
}

sub _mention_after_unique ( $self, $row, $error ) {
    if ( _mention_id_conflict($error) ) {
        return $self->_mention_after_id_conflict($row);
    }
    if ( _mention_source_conflict($error) ) {
        return $self->_reuse_mention_row( $row, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _mention_after_id_conflict ( $self, $row ) {
    my $existing = $self->_existing_mention($row);
    if ($existing) {
        my $undefined;
        return $undefined;
    }

    return $self->_retry_mention_id($row);
}

sub _retry_mention_id ( $self, $row ) {
    $row->{mention_id} = $self->id_service->uuid;
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_mention($row); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reuse_mention_row ( $self, $row, $error ) {
    my $existing = $self->_existing_mention($row);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return;
}

sub _mention_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _mention_source_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $SOURCE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _capture_mention_notification ( $self, $row, $ctx ) {
    my $accepted = $self->_accepted_notification( $ctx->{input}, $row );
    if ($accepted) {
        push @{ $ctx->{notifications} }, $accepted;
    }

    return;
}

sub _notify_mentions ( $self, $input, $mentions ) {
    my @notifications;
    for my $mention ( @{$mentions} ) {
        my $accepted = $self->_accepted_notification( $input, $mention );
        if ($accepted) {
            push @notifications, $accepted;
        }
    }

    return @notifications;
}

sub _accepted_notification ( $self, $input, $mention ) {
    my $undefined;

    my $result = $self->_notify_mention( $input, $mention );
    if ( !$result ) {
        return $undefined;
    }
    if ( !$result->{ok} ) {
        return $undefined;
    }
    if ( $result->{duplicate} ) {
        return $undefined;
    }

    return $result;
}

sub _notify_mention ( $self, $input, $mention ) {
    if ( !$self->notification_dispatcher ) {
        my $undefined;
        return $undefined;
    }

    return $self->notification_dispatcher->create_notification(
        {
            notification_type => 'mention',
            payload           => {
                actor_id           => $input->{actor_id},
                mentioned_username => $mention->{mentioned_username},
                post_id            => _payload_post_id($input),
                source_id          => $input->{source_id},
                source_type        => $input->{source_type},
                thread_id          => $input->{thread_id},
            },
            recipient_user_id => $mention->{mentioned_user_id},
            source_id         => $input->{source_id},
            source_type       => $input->{source_type},
        }
    );
}

sub _payload_post_id ($input) {
    return $input->{source_id} if $input->{source_type} eq 'post';

    my $undefined;
    return $undefined;
}

sub _existing_mention ( $self, $row ) {
    return $self->schema->resultset('Mention')->find(
        {
            source_type       => $row->{source_type},
            source_id         => $row->{source_id},
            mentioned_user_id => $row->{mentioned_user_id},
        }
    );
}

sub _resolve_users ( $self, $mentions ) {
    my @usernames = map { $_->{username} } @{$mentions};
    my $search    = $self->schema->resultset('User')->search_rs(
        {
            username   => { -in => \@usernames },
            deleted_at => undef,
        },
        {
            columns => [qw(id username)],
            rows    => scalar @usernames,
        }
    );

    my %resolved;
    for my $user ( _rows($search) ) {
        my $username = lc _column( $user, 'username' );
        $resolved{$username} = $user;
    }

    return \%resolved;
}

sub _empty_result {
    return {
        ok            => 1,
        created       => [],
        notifications => [],
        skipped       => [],
    };
}

sub _skip ( $mention, $reason ) {
    return {
        username => $mention->{username},
        reason   => $reason,
    };
}

sub _column ( $row, $column ) {
    return GPForum::Infrastructure::Row->column( $row, $column );
}

sub _uuid_or_undef ($value) {
    return defined $value
      && $value =~
/\A [[:xdigit:]]{8} - [[:xdigit:]]{4} - [[:xdigit:]]{4} - [[:xdigit:]]{4} - [[:xdigit:]]{12} \z/msx
      ? $value
      : undef;
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Community::MentionStore - Record the mentions in a post and notify the people mentioned.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $mentions = GPForum::Service::Community::MentionStore->new(
        notification_dispatcher => $notification_dispatcher,
        readability => GPForum::Service::Forum::Readability->new(
            schema => $schema,
        ),
        schema => $schema,
    );
    my $result = $mentions->record_for_source(
        {
            actor_id     => $author_id,
            body_source  => $body_source,
            max_mentions => 10,
            source_id    => $post_id,
            source_type  => 'post',
            thread_id    => $thread_id,
        }
    );
    # { ok => 1, created => [...], notifications => [...], skipped => [...] }

=head1 DESCRIPTION

Turns the C<@username> mentions found by
L<GPForum::Service::Community::MentionExtractor> into C<mentions> rows and
C<mention> notifications. A mention is not recorded when the username
matches no user (deleted users are not looked up), when it names the
author, or when the
mentioned user cannot read the source (ADR 0102): a mention of someone who
cannot read the post would otherwise notify them and list the thread on
their mentions page.

The number of mentions one body can fan out to is capped (10 by default);
the ones past the cap are skipped and the cut is audited as
C<mention.fanout_limited>, so a post cannot be used to notify a crowd.

Recording is idempotent per source and mentioned user, which a unique
index enforces. A mention already recorded is not inserted again, but its
notification is requested again, and a result the dispatcher marks as a
duplicate is left out. Inserts run under savepoints
through L<GPForum::Infrastructure::UniqueConflict>, so a conflict with a
concurrent writer does not abort the transaction.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is required. C<notification_dispatcher>
(an object with C<create_notification>, such as
L<GPForum::Service::Notification::Dispatcher>) and C<readability> (an
object with C<readable_by>, such as L<GPForum::Service::Forum::Readability>)
are optional: without the first no notification is sent, without the
second every resolved user is taken to be able to read the source.
C<clock>, C<extractor>, C<id_service> and C<recorder> have defaults.

=head2 record_for_source

Takes a hash reference with C<body_source> (the text to scan),
C<source_type>, C<source_id>, C<actor_id> (the author), C<thread_id> (put
into the notification payload) and an optional C<max_mentions> (10 when
absent or zero). Runs the inserts and notifications in one transaction when
the schema has C<txn_do>.

Returns a hash reference with C<< ok => 1 >>, C<created> (the hashes of the
mention rows inserted), C<notifications> (the dispatcher's results for the
notifications it accepted and did not report as duplicates) and C<skipped>
(C<< { username, reason } >> entries with reason C<unknown_user>,
C<self_mention>, C<source_not_readable> or C<fanout_limited>). A body
without mentions returns empty lists and touches nothing.

=head1 DIAGNOSTICS

Database errors other than the two handled unique conflicts (on the
mention id and on source and mentioned user) are rethrown, as is a
conflict on the source whose existing row cannot be found, and the
transaction rolls back. A failure to write the fan-out audit is ignored.
L<GPForum::Service::Forum::PostingWorkflow> calls this inside an C<eval> so
that a failed mention does not fail the post.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Community::MentionExtractor>,
L<GPForum::Infrastructure::EventRecorder>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Infrastructure::Row>,
L<GPForum::Infrastructure::Id>, L<GPForum::Service::Clock>.

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
