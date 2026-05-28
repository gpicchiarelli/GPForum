package GPForum::Service::Community::MentionStore;

use strict;
use warnings;

use Mojo::Base -base;

use Const::Fast;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Clock;
use GPForum::Service::Community::MentionExtractor;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $DEFAULT_MAX_MENTIONS => 10;
const my $SCHEMA_VERSION       => 1;

has clock => sub { return GPForum::Service::Clock->new; };
has extractor =>
  sub { return GPForum::Service::Community::MentionExtractor->new; };
has id_service              => sub { return GPForum::Service::Id->new; };
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

    my @created;
    my @skipped;

    for my $mention ( @{$mentions} ) {
        my $user = $resolved->{ $mention->{username} };
        if ( !$user ) {
            push @skipped, _skip( $mention, 'unknown_user' );
            next;
        }

        my $mentioned_user_id = _column( $user, 'id' );
        if ( $mentioned_user_id eq $input->{actor_id} ) {
            push @skipped, _skip( $mention, 'self_mention' );
            next;
        }

        my $row = {
            mention_id         => $self->id_service->uuid,
            source_type        => $input->{source_type},
            source_id          => $input->{source_id},
            actor_id           => $input->{actor_id},
            mentioned_user_id  => $mentioned_user_id,
            mentioned_username => $mention->{username},
            created_at         => $self->clock->now_iso8601,
        };

        next if $self->_existing_mention($row);

        $self->schema->resultset('Mention')->create($row);
        push @created, $row;
    }

    my @notifications = $self->_notify_mentions( $input, \@created );

    return {
        ok            => 1,
        created       => \@created,
        notifications => \@notifications,
        skipped       => \@skipped,
    };
}

sub _notify_mentions {
    my ( $self, $input, $mentions ) = @_;

    return if !$self->notification_dispatcher;

    my @notifications;
    for my $mention ( @{$mentions} ) {
        my $result = $self->notification_dispatcher->create_notification(
            {
                recipient_user_id => $mention->{mentioned_user_id},
                source_type       => $input->{source_type},
                source_id         => $input->{source_id},
                notification_type => 'mention',
                payload           => {
                    actor_id           => $input->{actor_id},
                    mentioned_username => $mention->{mentioned_username},
                    source_type        => $input->{source_type},
                    source_id          => $input->{source_id},
                    thread_id          => $input->{thread_id},
                    post_id            => _payload_post_id($input),
                },
            }
        );
        if ( $result->{ok} ) {
            push @notifications, $result;
        }
    }

    return @notifications;
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
