package GPForum::Service::Notification::PreferenceStore;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my @CHANNELS           => qw(in_app email digest);
const my @DIGEST_FREQUENCIES => qw(immediate daily weekly never);
const my %CHANNEL_DEFAULTS => (
    digest => {
        digest_frequency => 'daily',
        enabled          => 0,
    },
    email => {
        digest_frequency => 'daily',
        enabled          => 1,
    },
    in_app => {
        digest_frequency => 'immediate',
        enabled          => 1,
    },
);

has clock  => sub { return GPForum::Service::Clock->new; };
has schema => undef;

sub set_preference {
    my ( $self, $input ) = @_;

    my $normalized = _normalized_preference($input);
    my $existing   = $self->_existing_preference($normalized);
    if ( _same_stored_preference( $existing, $normalized ) ) {
        return _skipped_preference($existing);
    }
    if ($existing) {
        return $self->_persist_preference($normalized);
    }

    return $self->_insert_or_reuse_preference($normalized);
}

sub _insert_or_reuse_preference {
    my ( $self, $normalized ) = @_;

    my $created = eval { return $self->_insert_preference($normalized); };
    if ($created) {
        return $created;
    }

    return $self->_preference_after_conflict( $normalized, $EVAL_ERROR );
}

sub _preference_after_conflict {
    my ( $self, $normalized, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $existing = $self->_existing_preference($normalized);
    if ( !_same_stored_preference( $existing, $normalized ) ) {
        return $self->_write_after_conflict( $existing, $normalized, $error );
    }

    return _skipped_preference($existing);
}

sub _write_after_conflict {
    my ( $self, $existing, $normalized, $error ) = @_;

    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_persist_preference($normalized);
}

sub _insert_preference {
    my ( $self, $normalized ) = @_;

    my $row = { %{$normalized}, updated_at => $self->clock->now_iso8601, };
    $self->schema->resultset('NotificationPreference')->create($row);

    return $row;
}

sub _normalized_preference {
    my ($input) = @_;

    return {
        channel          => _safe_channel( $input->{channel} ),
        digest_frequency =>
          _safe_digest_frequency( $input->{digest_frequency} ),
        enabled => $input->{enabled} ? 1 : 0,
        user_id => $input->{user_id},
    };
}

sub _existing_preference {
    my ( $self, $normalized ) = @_;

    return $self->schema->resultset('NotificationPreference')->find(
        {
            channel => $normalized->{channel},
            user_id => $normalized->{user_id},
        }
    );
}

sub _same_stored_preference {
    my ( $existing, $normalized ) = @_;

    if ( !$existing ) {
        return 0;
    }
    if ( !_enabled_matches( $existing, $normalized->{enabled} ) ) {
        return 0;
    }
    if ( !_digest_matches( $existing, $normalized->{digest_frequency} ) ) {
        return 0;
    }

    return 1;
}

sub _enabled_matches {
    my ( $existing, $enabled ) = @_;

    my $held = _column( $existing, 'enabled' ) ? 1 : 0;
    return $held eq $enabled ? 1 : 0;
}

sub _digest_matches {
    my ( $existing, $digest ) = @_;

    my $held = _column( $existing, 'digest_frequency' ) || q{};
    return $held eq $digest ? 1 : 0;
}

sub _skipped_preference {
    my ($existing) = @_;

    my $payload = _preference_payload($existing);
    $payload->{skipped} = 1;

    return $payload;
}

sub _preference_payload {
    my ($existing) = @_;

    return {
        channel          => _column( $existing, 'channel' ),
        digest_frequency => _column( $existing, 'digest_frequency' ),
        enabled          => _column( $existing, 'enabled' ) ? 1 : 0,
        updated_at       => _column( $existing, 'updated_at' ),
        user_id          => _column( $existing, 'user_id' ),
    };
}

sub _persist_preference {
    my ( $self, $normalized ) = @_;

    my $row = { %{$normalized}, updated_at => $self->clock->now_iso8601, };
    $self->schema->resultset('NotificationPreference')->update_or_create($row);

    return $row;
}

sub set_preferences {
    my ( $self, $input ) = @_;

    for my $preference ( @{ $input->{preferences} || [] } ) {
        $self->set_preference(
            {
                %{$preference}, user_id => $input->{user_id},
            }
        );
    }

    return $self->preferences_for_user( $input->{user_id} );
}

sub preferences_for_user {
    my ( $self, $user_id ) = @_;

    my %stored;
    my $search = $self->schema->resultset('NotificationPreference')->search(
        {
            user_id => $user_id,
        }
    );
    for my $row ( _rows($search) ) {
        my $channel = _column( $row, 'channel' );
        next if !_is_channel($channel);
        $stored{$channel} = {
            channel          => $channel,
            digest_frequency =>
              _safe_digest_frequency( _column( $row, 'digest_frequency' ) ),
            enabled => _column( $row, 'enabled' ) ? 1 : 0,
            user_id => _column( $row, 'user_id' ),
        };
    }

    return [
        map {
            my $default = $CHANNEL_DEFAULTS{$_};
            +{
                %{$default},
                %{ $stored{$_} || {} },
                channel         => $_,
                description_key => 'notifications.preference.'
                  . $_
                  . '.description',
                label_key => 'notifications.channel.' . $_,
            }
        } @CHANNELS
    ];
}

sub channel_enabled {
    my ( $self, $user_id, $channel ) = @_;

    my $safe_channel = _safe_channel($channel);
    for my $preference ( @{ $self->preferences_for_user($user_id) } ) {
        next if $preference->{channel} ne $safe_channel;

        return $preference->{enabled} ? 1 : 0;
    }

    return 1;
}

sub channel_names {
    return [@CHANNELS];
}

sub digest_frequency_options {
    return [
        map {
            +{
                label_key => 'notifications.digest_frequency.' . $_,
                value     => $_,
            }
        } @DIGEST_FREQUENCIES
    ];
}

sub enabled_channels {
    my ( $self, $user_id ) = @_;

    my $search = $self->schema->resultset('NotificationPreference')->search(
        {
            user_id => $user_id,
            enabled => 1,
        }
    );

    return map { $_->get_column('channel') } _rows($search);
}

sub _safe_channel {
    my ($channel) = @_;

    return $channel if _is_channel($channel);

    return 'in_app';
}

sub _is_channel {
    my ($channel) = @_;

    return grep { $_ eq ( $channel || q{} ) } @CHANNELS;
}

sub _safe_digest_frequency {
    my ($frequency) = @_;

    for my $allowed (@DIGEST_FREQUENCIES) {
        return $allowed if defined $frequency && $frequency eq $allowed;
    }

    return 'daily';
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row && $row->can('get_column');

    return;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
