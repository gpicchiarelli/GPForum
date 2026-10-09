# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Notification::PreferenceStore;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::X::Conflict;

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

has clock => sub { return GPForum::Service::Clock->new; };
__PACKAGE__->requires(qw(schema));

# A preference already holding these values is skipped; any other is
# written. The preference is keyed by member and channel: a conflict on the
# insert is another request's row, which this write then replaces unless it
# already holds the same values.
sub set_preference ( $self, $input ) {
    my $refused = _refused_channel( $input->{channel} );
    if ($refused) {
        return $refused;
    }

    my $normalized = {
        channel          => $input->{channel},
        digest_frequency =>
          _safe_digest_frequency( $input->{digest_frequency} ),
        enabled => $input->{enabled} ? 1 : 0,
        user_id => $input->{user_id},
    };
    my $existing = $self->_existing_preference($normalized);
    if ( !$existing ) {
        my ( $created, $error ) =
          GPForum::Infrastructure::UniqueConflict->attempt(
            $self->schema,
            sub {
                my $row =
                  { %{$normalized}, updated_at => $self->clock->now_iso8601 };
                $self->schema->resultset('NotificationPreference')
                  ->create($row);
                return $row;
            },
          );
        if ($created) {
            return $created;
        }
        $existing =
          GPForum::X::Conflict->caught($error)
          ? $self->_existing_preference($normalized)
          : undef;
        if ( !$existing ) {
            GPForum::Infrastructure::UniqueConflict->rethrow($error);
        }
    }

    my $enabled = _column( $existing, 'enabled' ) ? 1 : 0;
    my $digest  = _column( $existing, 'digest_frequency' ) || q{};
    if (   $enabled eq $normalized->{enabled}
        && $digest eq $normalized->{digest_frequency} )
    {
        return {
            channel          => _column( $existing, 'channel' ),
            digest_frequency => _column( $existing, 'digest_frequency' ),
            enabled          => $enabled,
            skipped          => 1,
            updated_at       => _column( $existing, 'updated_at' ),
            user_id          => _column( $existing, 'user_id' ),
        };
    }

    my $row = { %{$normalized}, updated_at => $self->clock->now_iso8601, };
    $self->schema->resultset('NotificationPreference')->update_or_create($row);

    return $row;
}

sub _existing_preference ( $self, $normalized ) {
    return $self->schema->resultset('NotificationPreference')->find(
        {
            channel => $normalized->{channel},
            user_id => $normalized->{user_id},
        }
    );
}

# Every channel is checked before any is written, so a refused request
# leaves the member's preferences as they were.
sub set_preferences ( $self, $input ) {
    my @preferences = @{ $input->{preferences} || [] };
    for my $preference (@preferences) {
        my $refused = _refused_channel( $preference->{channel} );
        if ($refused) {
            return $refused;
        }
    }

    for my $preference (@preferences) {
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

    my @preferences;
    for my $channel (@CHANNELS) {
        push @preferences,
          {
            %{ $CHANNEL_DEFAULTS{$channel} },
            %{ $stored{$channel} || {} },
            channel         => $channel,
            description_key => "notifications.preference.$channel.description",
            label_key       => "notifications.channel.$channel",
          };
    }

    return \@preferences;
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

# Read through the defaults, as channel_enabled is. Read from the stored
# rows alone, a member who never saved the settings form had no channel on,
# though every delivery treated in-app and email as on.
sub enabled_channels ( $self, $user_id ) {
    return map { $_->{channel} }
      grep { $_->{enabled} } @{ $self->preferences_for_user($user_id) };
}

# A misspelt channel was written as in_app: a request meant for email turned
# the member's in-app notifications off. It is refused instead, as invalid
# input, before anything is written.
sub _refused_channel ($channel) {
    if ( _is_channel($channel) ) {
        return undef;
    }

    my $message = 'channel must be one of ' . join q{, }, @CHANNELS;

    return {
        error  => $message,
        errors => { channel => $message },
        ok     => 0,
        status => 'invalid',
    };
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

A write names a known channel or is refused: an unknown channel is
answered with C<< { ok => 0, status => 'invalid', error, errors =>
{ channel } } >> and nothing is written, which the notification workflow
passes up as an invalid request (a 400 from the settings form). The rest of
the input is coerced: an unknown digest frequency is stored as C<daily>, and
C<enabled> as a boolean. A write that would store what is already stored is
skipped, and an insert that loses a race with a concurrent one for the same
member and channel falls back to the row that won.

=head1 SUBROUTINES/METHODS

=head2 set_preference

Takes a hash reference with C<user_id>, C<channel>, C<enabled> and
C<digest_frequency>, checked and coerced as above. Returns the refusal hash
reference when the channel is unknown; otherwise the hash reference written
(C<user_id>, C<channel>, C<enabled>, C<digest_frequency>, C<updated_at>), or,
when the stored row already says the same, that row's values with
C<< skipped => 1 >> and nothing written. A new row is inserted under a
savepoint.

=head2 set_preferences

Takes C<user_id> and C<preferences>, an array reference of hashes as for
L</set_preference> (the outer C<user_id> wins). When any of them names an
unknown channel, returns the refusal hash reference and writes none of
them. Otherwise applies each in order and returns L</preferences_for_user>
(an array reference) for that member.

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

Takes a user id and returns a list of the channel names that are on for the
member, in the order of L</preferences_for_user> and with its defaults: a
member with no stored rows gets C<in_app> and C<email>.

=head1 DIAGNOSTICS

An unknown channel is not raised: L</set_preference> and
L</set_preferences> return C<< { ok => 0, status => 'invalid' } >> with
C<error> and C<< errors => { channel } >> saying
C<channel must be one of in_app, email, digest>. L</set_preference> rethrows
an insert error that is not a unique conflict, and a unique conflict after
which no row can be found. Other database errors propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::Row>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::X::Conflict>,
L<GPForum::Service::Clock>.

Extends L<GPForum::Base>: built without C<schema> it throws
L<GPForum::X::Argument>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

L</channel_enabled> still reads an unknown channel as C<in_app>. Nothing in
F<lib/> calls L</enabled_channels>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
