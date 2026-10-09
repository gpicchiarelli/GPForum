# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Base;

use Mojo::Base 'Mojolicious::Controller', -signatures;
use v5.40;

use GPForum::Web::Responder;

our $VERSION = '0.001';

# A write's command id: the Forum-style command_id field, or the older
# idempotency_key; empty when neither is given.
sub command_id_param ($self) {
    my $command_id = $self->_trim( $self->param('command_id') );
    if ( length $command_id ) {
        return $command_id;
    }

    return $self->_trim( $self->param('idempotency_key') );
}

# undef for an empty filter, never an empty list, so a hash built from it
# keeps its pairs.
sub optional_param ( $self, $name ) {
    my $value = $self->_trim( $self->param($name) );
    if ( length $value ) {
        return $value;
    }

    return undef;
}

sub render_payload ( $self, $input ) {
    return GPForum::Web::Responder->new->payload(
        {
            controller => $self,
            payload    => $input->{payload},
            status     => $input->{status},
            template   => $input->{template},
        }
    );
}

sub global_permission_scope {
    return {
        resource_id => undef,
        space_id    => undef,
    };
}

sub set_success_flash ( $self, $flash_key ) {
    if ( !$flash_key ) {
        return;
    }

    $self->flash( success => $self->t($flash_key) );

    return;
}

sub _trim ( $, $value ) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

1;

__END__

=head1 NAME

GPForum::Controller::Base - Request helpers every GPForum controller base
shares.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use Mojo::Base 'GPForum::Controller::Base', -signatures;

    my $command_id = $self->command_id_param;
    my $after      = $self->optional_param('after');

=head1 DESCRIPTION

The admin, attachment, forum, identity, moderation, notification and privacy
controller bases inherit from this class instead of each carrying its own
copy of these helpers. A base whose rule differs, such as the forum's
C<render_payload>, overrides it.

=head1 SUBROUTINES/METHODS

=head2 command_id_param

Returns the trimmed C<command_id> parameter, or the trimmed
C<idempotency_key> when C<command_id> is empty; an empty string when neither
is given.

=head2 optional_param

Returns the trimmed parameter, or undef when it is missing or blank. It is
undef, not an empty list, in list context too.

=head2 render_payload

Renders a payload hash as JSON or through its template, following the
request, via L<GPForum::Web::Responder/payload>.

=head2 global_permission_scope

Returns the explicit unscoped permission scope: both C<resource_id> and
C<space_id> undefined. L<GPForum::Service::Admin::PermissionGate> then
accepts global role bindings only.

=head2 set_success_flash

Sets the C<success> flash to the translation of a flash key; does nothing
without one.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the C<t> translation helper registered during application startup.

=head1 DEPENDENCIES

L<Mojolicious::Controller>, L<GPForum::Web::Responder>.

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
