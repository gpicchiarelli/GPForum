package GPForum::Service::Identity::PreferenceStore;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Identity::Support;

our $VERSION = '0.001';

has clock   => sub { return GPForum::Service::Clock->new; };
has schema  => undef;
has support => sub { return GPForum::Service::Identity::Support->new; };

sub preferred_locale_for_user {
    my ( $self, $input ) = @_;

    return $self->_read_preference( $input, 'preferred_locale' );
}

sub preferred_theme_for_user {
    my ( $self, $input ) = @_;

    return $self->_read_preference( $input, 'preferred_theme' );
}

sub update_preferred_locale {
    my ( $self, $input ) = @_;

    return $self->_update_preference(
        {
            column   => 'preferred_locale',
            input    => $input,
            required => 'locale_required',
        }
    );
}

sub update_preferred_theme {
    my ( $self, $input ) = @_;

    return $self->_update_preference(
        {
            column   => 'preferred_theme',
            input    => $input,
            required => 'theme_required',
        }
    );
}

sub _read_preference {
    my ( $self, $input, $column ) = @_;

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

sub _update_preference {
    my ( $self, $command ) = @_;

    my $user = $self->_find_user_by_id( $command->{input}{user_id} );
    if ( !$user ) {
        return { error => 'not_found', ok => 0 };
    }

    return $self->_write_preference( $user, $command );
}

sub _write_preference {
    my ( $self, $user, $command ) = @_;

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

sub _same_preference {
    my ( $held, $incoming ) = @_;

    if ( !defined $held ) {
        return 0;
    }

    return $held eq $incoming ? 1 : 0;
}

sub _find_user_by_id {
    my ( $self, $user_id ) = @_;

    if ( !$self->support->has_text($user_id) ) {
        return;
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
