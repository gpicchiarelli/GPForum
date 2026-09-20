package GPForum::Service::Community::MentionStore;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

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
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has notification_dispatcher => undef;
has recorder                => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;

sub record_for_source {
    my ( $self, $input ) = @_;

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

sub _limit_mentions {
    my ( $self, $input, $mentions ) = @_;

    my $max_mentions = $input->{max_mentions} || $DEFAULT_MAX_MENTIONS;
    return { mentions => $mentions, skipped => [] }
      if @{$mentions} <= $max_mentions;

    my @allowed = @{$mentions}[ 0 .. $max_mentions - 1 ];
    my @blocked = @{$mentions}[ $max_mentions .. $#{$mentions} ];
    my @skipped = map { _skip( $_, 'fanout_limited' ) } @blocked;
    $self->_record_fanout_audit( $input, scalar @blocked, $max_mentions );

    return { mentions => \@allowed, skipped => \@skipped };
}

sub _record_fanout_audit {
    my ( $self, $input, $blocked_count, $max_mentions ) = @_;

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

sub _insert_mentions {
    my ( $self, $input, $mentions, $resolved ) = @_;

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

sub _record_mention {
    my ( $self, $mention, $ctx ) = @_;

    my $user = $ctx->{resolved}{ $mention->{username} };
    if ( !$user ) {
        push @{ $ctx->{skipped} }, _skip( $mention, 'unknown_user' );
        return;
    }

    $ctx->{user} = $user;

    return $self->_record_resolved( $mention, $ctx );
}

sub _record_resolved {
    my ( $self, $mention, $ctx ) = @_;

    my $mentioned_user_id = _column( $ctx->{user}, 'id' );
    if ( $mentioned_user_id eq $ctx->{input}{actor_id} ) {
        push @{ $ctx->{skipped} }, _skip( $mention, 'self_mention' );
        return;
    }

    return $self->_insert_or_reuse_mention( $mention, $ctx );
}

sub _insert_or_reuse_mention {
    my ( $self, $mention, $ctx ) = @_;

    my $row = $self->_mention_row( $mention, $ctx );
    if ( $self->_existing_mention($row) ) {
        $self->_capture_mention_notification( $row, $ctx );
        return;
    }

    return $self->_create_or_reuse_mention( $row, $ctx );
}

sub _create_or_reuse_mention {
    my ( $self, $row, $ctx ) = @_;

    my $created = eval { return $self->_create_mention($row); };
    if ($created) {
        push @{ $ctx->{created} }, $created;
        return;
    }

    my $recovered = $self->_mention_after_conflict( $row, $EVAL_ERROR );
    if ($recovered) {
        push @{ $ctx->{created} }, $recovered;
        return;
    }

    $self->_capture_mention_notification( $row, $ctx );
    return;
}

sub _create_mention {
    my ( $self, $row ) = @_;

    $self->schema->resultset('Mention')->create($row);

    return $row;
}

sub _mention_row {
    my ( $self, $mention, $ctx ) = @_;

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

sub _mention_after_conflict {
    my ( $self, $row, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_mention_after_unique( $row, $error );
}

sub _mention_after_unique {
    my ( $self, $row, $error ) = @_;

    if ( _mention_id_conflict($error) ) {
        return $self->_mention_after_id_conflict($row);
    }
    if ( _mention_source_conflict($error) ) {
        return $self->_reuse_mention_row( $row, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _mention_after_id_conflict {
    my ( $self, $row ) = @_;

    my $existing = $self->_existing_mention($row);
    if ($existing) {
        return;
    }

    return $self->_retry_mention_id($row);
}

sub _retry_mention_id {
    my ( $self, $row ) = @_;

    $row->{mention_id} = $self->id_service->uuid;
    my $created = eval { return $self->_create_mention($row); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reuse_mention_row {
    my ( $self, $row, $error ) = @_;

    my $existing = $self->_existing_mention($row);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return;
}

sub _mention_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _mention_source_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $SOURCE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _capture_mention_notification {
    my ( $self, $row, $ctx ) = @_;

    my $accepted = $self->_accepted_notification( $ctx->{input}, $row );
    if ($accepted) {
        push @{ $ctx->{notifications} }, $accepted;
    }

    return;
}

sub _notify_mentions {
    my ( $self, $input, $mentions ) = @_;

    my @notifications;
    for my $mention ( @{$mentions} ) {
        my $accepted = $self->_accepted_notification( $input, $mention );
        if ($accepted) {
            push @notifications, $accepted;
        }
    }

    return @notifications;
}

sub _accepted_notification {
    my ( $self, $input, $mention ) = @_;

    my $result = $self->_notify_mention( $input, $mention );
    if ( !$result ) {
        return;
    }
    if ( !$result->{ok} ) {
        return;
    }
    if ( $result->{duplicate} ) {
        return;
    }

    return $result;
}

sub _notify_mention {
    my ( $self, $input, $mention ) = @_;

    if ( !$self->notification_dispatcher ) {
        return;
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

sub _payload_post_id {
    my ($input) = @_;

    return $input->{source_id} if $input->{source_type} eq 'post';

    return;
}

sub _existing_mention {
    my ( $self, $row ) = @_;

    return $self->schema->resultset('Mention')->find(
        {
            source_type       => $row->{source_type},
            source_id         => $row->{source_id},
            mentioned_user_id => $row->{mentioned_user_id},
        }
    );
}

sub _resolve_users {
    my ( $self, $mentions ) = @_;

    my @usernames = map { $_->{username} } @{$mentions};
    my $search    = $self->schema->resultset('User')->search(
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

sub _skip {
    my ( $mention, $reason ) = @_;

    return {
        username => $mention->{username},
        reason   => $reason,
    };
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row && $row->can('get_column');

    return;
}

sub _uuid_or_undef {
    my ($value) = @_;

    return defined $value
      && $value =~
/\A [[:xdigit:]]{8} - [[:xdigit:]]{4} - [[:xdigit:]]{4} - [[:xdigit:]]{4} - [[:xdigit:]]{12} \z/msx
      ? $value
      : undef;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
