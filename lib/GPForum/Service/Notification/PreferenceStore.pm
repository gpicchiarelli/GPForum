# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Notification::PreferenceStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
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

sub set_preference ( $self, $input ) {
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

sub _insert_or_reuse_preference ( $self, $normalized ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_preference($normalized); },
      );
    if ($created) {
        return $created;
    }

    return $self->_preference_after_conflict( $normalized, $error );
}

sub _preference_after_conflict ( $self, $normalized, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $existing = $self->_existing_preference($normalized);
    if ( !_same_stored_preference( $existing, $normalized ) ) {
        return $self->_write_after_conflict( $existing, $normalized, $error );
    }

    return _skipped_preference($existing);
}

sub _write_after_conflict ( $self, $existing, $normalized, $error ) {
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_persist_preference($normalized);
}

sub _insert_preference ( $self, $normalized ) {
    my $row = { %{$normalized}, updated_at => $self->clock->now_iso8601, };
    $self->schema->resultset('NotificationPreference')->create($row);

    return $row;
}

sub _normalized_preference ($input) {
    return {
        channel          => _safe_channel( $input->{channel} ),
        digest_frequency =>
          _safe_digest_frequency( $input->{digest_frequency} ),
        enabled => $input->{enabled} ? 1 : 0,
        user_id => $input->{user_id},
    };
}

sub _existing_preference ( $self, $normalized ) {
    return $self->schema->resultset('NotificationPreference')->find(
        {
            channel => $normalized->{channel},
            user_id => $normalized->{user_id},
        }
    );
}

sub _same_stored_preference ( $existing, $normalized ) {
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

sub _enabled_matches ( $existing, $enabled ) {
    my $held = _column( $existing, 'enabled' ) ? 1 : 0;
    return $held eq $enabled ? 1 : 0;
}

sub _digest_matches ( $existing, $digest ) {
    my $held = _column( $existing, 'digest_frequency' ) || q{};
    return $held eq $digest ? 1 : 0;
}

sub _skipped_preference ($existing) {
    my $payload = _preference_payload($existing);
    $payload->{skipped} = 1;

    return $payload;
}

sub _preference_payload ($existing) {
    return {
        channel          => _column( $existing, 'channel' ),
        digest_frequency => _column( $existing, 'digest_frequency' ),
        enabled          => _column( $existing, 'enabled' ) ? 1 : 0,
        updated_at       => _column( $existing, 'updated_at' ),
        user_id          => _column( $existing, 'user_id' ),
    };
}

sub _persist_preference ( $self, $normalized ) {
    my $row = { %{$normalized}, updated_at => $self->clock->now_iso8601, };
    $self->schema->resultset('NotificationPreference')->update_or_create($row);

    return $row;
}

sub set_preferences ( $self, $input ) {
    for my $preference ( @{ $input->{preferences} || [] } ) {
        $self->set_preference(
            {
                %{$preference}, user_id => $input->{user_id},
            }
        );
    }

    return $self->preferences_for_user( $input->{user_id} );
}

sub preferences_for_user ( $self, $user_id ) {
    my %stored;
    my $search = $self->schema->resultset('NotificationPreference')->search_rs(
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

sub channel_enabled ( $self, $user_id, $channel ) {
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

sub enabled_channels ( $self, $user_id ) {
    my $search = $self->schema->resultset('NotificationPreference')->search_rs(
        {
            user_id => $user_id,
            enabled => 1,
        }
    );

    return map { $_->get_column('channel') } _rows($search);
}

sub _safe_channel ($channel) {
    return $channel if _is_channel($channel);

    return 'in_app';
}

sub _is_channel ($channel) {
    return grep { $_ eq ( $channel || q{} ) } @CHANNELS;
}

sub _safe_digest_frequency ($frequency) {
    for my $allowed (@DIGEST_FREQUENCIES) {
        return $allowed if defined $frequency && $frequency eq $allowed;
    }

    return 'daily';
}

sub _column ( $row, $column ) {
    return GPForum::Infrastructure::Row->column( $row, $column );
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Notification::PreferenceStore - A member's notification channel preferences.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Notification::PreferenceStore->new(
        schema => $schema );
    $store->set_preference(
        {
            user_id          => $user_id,
            channel          => 'email',
            enabled          => 0,
            digest_frequency => 'daily',
        }
    );
    my $rows  = $store->preferences_for_user($user_id);
    my $email = $store->channel_enabled( $user_id, 'email' );

=head1 DESCRIPTION

One row per member and channel in C<notification_preferences>, for the three
channels C<in_app>, C<email> and C<digest>. A member with no row has the
defaults: in-app on and immediate, email on with a daily digest frequency,
digest off and daily. The settings page reads and writes through this store,
and the notification dispatcher asks it whether a channel is on.

Input is coerced rather than refused: an unknown channel is treated as
C<in_app>, an unknown digest frequency as C<daily>, and C<enabled> as a
boolean. A write that would store what is already stored is skipped, and an
insert that loses a race with a concurrent one for the same member and
channel falls back to the row that won.

=head1 SUBROUTINES/METHODS

=head2 set_preference

Takes a hash reference with C<user_id>, C<channel>, C<enabled> and
C<digest_frequency>, coerced as above. Returns the hash reference written
(C<user_id>, C<channel>, C<enabled>, C<digest_frequency>, C<updated_at>), or,
when the stored row already says the same, that row's values with
C<< skipped => 1 >> and nothing written. A new row is inserted under a
savepoint.

=head2 set_preferences

Takes C<user_id> and C<preferences>, an array reference of hashes as for
L</set_preference> (the outer C<user_id> wins), applies each in order, and
returns L</preferences_for_user> for that member.

=head2 preferences_for_user

Takes a user id and returns an array reference with one hash per channel, in
the order C<in_app>, C<email>, C<digest>: C<channel>, C<enabled>,
C<digest_frequency>, C<user_id> (only when a row is stored), and the i18n
keys C<label_key> and C<description_key>. Stored values override the
defaults; a stored row for an unknown channel is ignored, and an unknown
stored frequency reads as C<daily>.

=head2 channel_enabled

Takes a user id and a channel (unknown reads as C<in_app>) and returns 1 or
0, from the stored row or the channel's default.

=head2 channel_names

Returns an array reference of the channel names. Needs no instance.

=head2 digest_frequency_options

Returns an array reference of C<< { value, label_key } >> for C<immediate>,
C<daily>, C<weekly> and C<never>. Needs no instance.

=head2 enabled_channels

Takes a user id and returns a list of the channel names whose stored row has
C<enabled> set. Unlike the methods above it applies no defaults and no
channel filter: a member with no stored rows gets an empty list.

=head1 DIAGNOSTICS

L</set_preference> rethrows an insert error that is not a unique conflict,
and a unique conflict after which no row can be found. Other database errors
propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::Row>,
L<GPForum::Infrastructure::UniqueConflict>,
L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A misspelt channel is written to C<in_app>, not refused. Nothing in
F<lib/> calls L</enabled_channels>, whose results differ from
L</channel_enabled> for a member without stored rows.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
