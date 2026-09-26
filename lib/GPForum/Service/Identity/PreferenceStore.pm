# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::PreferenceStore;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use DateTime::TimeZone;

use GPForum::Service::Clock;
use GPForum::Service::Identity::Support;

our $VERSION = '0.001';

has clock   => sub { return GPForum::Service::Clock->new; };
has schema  => undef;
has support => sub { return GPForum::Service::Identity::Support->new; };

sub preferred_locale_for_user ( $self, $input ) {
    return $self->_read_preference( $input, 'preferred_locale' );
}

sub preferred_theme_for_user ( $self, $input ) {
    return $self->_read_preference( $input, 'preferred_theme' );
}

sub update_preferred_locale ( $self, $input ) {
    return $self->_update_preference(
        {
            column   => 'preferred_locale',
            input    => $input,
            required => 'locale_required',
        }
    );
}

sub update_preferred_theme ( $self, $input ) {
    return $self->_update_preference(
        {
            column   => 'preferred_theme',
            input    => $input,
            required => 'theme_required',
        }
    );
}

# 9.3. Unlike locale and theme, empty is a choice: the forum's default zone,
# stored as NULL so a member who never chose follows it if it changes.
sub update_preferred_timezone ( $self, $input ) {
    my $user = $self->_find_user_by_id( $input->{user_id} );
    return { error => 'not_found', ok => 0 } if !$user;

    my $zone = $self->support->trim( $input->{preferred_timezone} );
    if ( length $zone && !DateTime::TimeZone->is_valid_name($zone) ) {
        return { error => 'timezone_invalid', ok => 0 };
    }

    my $value  = length $zone ? $zone : undef;
    my $held   = $self->support->column( $user, 'preferred_timezone' );
    my %answer = (
        ok                 => 1,
        preferred_timezone => $value,
        user               => $user,
    );
    return { %answer, skipped => 1 } if ( $held // q{} ) eq ( $value // q{} );

    $self->support->update_row(
        $user,
        {
            preferred_timezone => $value,
            updated_at         => $self->clock->now_iso8601,
        }
    );

    return \%answer;
}

sub _read_preference ( $self, $input, $column ) {
    my $user = $self->_find_user_by_id( $input->{user_id} );
    if ( !$user ) {
        return { error => 'not_found', ok => 0 };
    }

    return {
        ok      => 1,
        $column => $self->support->column( $user, $column ),
        user    => $user,
    };
}

sub _update_preference ( $self, $command ) {
    my $user = $self->_find_user_by_id( $command->{input}{user_id} );
    if ( !$user ) {
        return { error => 'not_found', ok => 0 };
    }

    return $self->_write_preference( $user, $command );
}

sub _write_preference ( $self, $user, $command ) {
    my $column  = $command->{column};
    my $trimmed = $self->support->trim( $command->{input}{$column} );
    if ( !length $trimmed ) {
        return { error => $command->{required}, ok => 0 };
    }

    my $held = $self->support->column( $user, $column );
    if ( _same_preference( $held, $trimmed ) ) {
        return {
            ok      => 1,
            skipped => 1,
            $column => $trimmed,
            user    => $user,
        };
    }

    $self->support->update_row(
        $user,
        {
            $column    => $trimmed,
            updated_at => $self->clock->now_iso8601,
        }
    );

    return {
        ok      => 1,
        $column => $trimmed,
        user    => $user,
    };
}

sub _same_preference ( $held, $incoming ) {
    if ( !defined $held ) {
        return 0;
    }

    return $held eq $incoming ? 1 : 0;
}

sub _find_user_by_id ( $self, $user_id ) {
    if ( !$self->support->has_text($user_id) ) {
        my $undefined;
        return $undefined;
    }

    return $self->schema->resultset('User')->find( { id => $user_id } );
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::PreferenceStore - Locale and theme persistence.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = $store->update_preferred_locale(
        {
            preferred_locale => $locale,
            user_id          => $user_id,
        }
    );

=head1 DESCRIPTION

Owns locale and theme preference reads and writes on the user row. The
identity store facade delegates to this object so HTTP and workflow callers
keep a stable API.

=head1 SUBROUTINES/METHODS

=head2 preferred_locale_for_user

Returns the stored locale for a user id.

=head2 update_preferred_timezone

Persists an IANA time zone, or NULL -- the forum's default -- for an empty
one. C<timezone_invalid> for a name the time zone database does not know.

=head2 preferred_theme_for_user

Returns the stored theme for a user id.

=head2 update_preferred_locale

Persists a non-empty locale and refreshes C<updated_at>. A second write of
the same locale returns C<skipped> and does not restamp the user row.

=head2 update_preferred_theme

Persists a non-empty theme and refreshes C<updated_at>. A second write of
the same theme returns C<skipped> and does not restamp the user row.

=head1 DIAGNOSTICS

Missing users return C<not_found>. Empty values return C<locale_required> or
C<theme_required>.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a DBIx::Class schema with a User resultset.

=head1 DEPENDENCIES

Uses L<GPForum::Service::Identity::Support>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Preference writes are not transactional with notification settings.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
