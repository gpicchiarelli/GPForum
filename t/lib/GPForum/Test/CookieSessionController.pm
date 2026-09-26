# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CookieSessionController;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has data    => sub { return {}; };
has expired => 0;

sub session {
    my ( $self, @args ) = @_;

    if ( @args <= 1 ) {
        return $self->_session_read( $args[0] );
    }

    return $self->_session_write(@args);
}

sub _session_read {
    my ( $self, $name ) = @_;

    if ( !defined $name ) {
        return $self->data;
    }

    return $self->data->{$name};
}

sub _session_write {
    my ( $self, @args ) = @_;

    if ( $args[0] eq 'expires' ) {
        $self->expired( $args[1] );
        return;
    }

    return $self->_merge_session(@args);
}

sub _merge_session {
    my ( $self, %values ) = @_;

    for my $key ( keys %values ) {
        $self->data->{$key} = $values{$key};
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Test::CookieSessionController - Cookie-session fake.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $controller = GPForum::Test::CookieSessionController->new(
        data => { user_id => 'user-1', session_id => 'sess-1' },
    );

=head1 DESCRIPTION

Test double for Mojolicious C<session> get/set/expire used by
C<Web::CookieSession>.

=head1 SUBROUTINES/METHODS

=head2 session

Reads a key, returns the session hash, merges values, or records expiry.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not emulate signed cookie serialization.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
