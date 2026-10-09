# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Identity::Profile;

use Const::Fast;
use GPForum::Web::ErrorPayload;
use Mojo::Base 'GPForum::Controller::Identity::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

const my $HTTP_NOT_FOUND => 404;
const my $HTTP_OK        => 200;

sub profile ($self) {
    my $result = $self->gp_profile_reader->public_profile(
        $self->param('username'),
        {
            limit => $self->identity_access->profile_thread_limit(
                $self->param('limit')
            ),
            after => $self->param('after'),
        }
    );
    if ( !$result->{ok} ) {
        if ( $self->_wants_json ) {
            return $self->render(
                json => GPForum::Web::ErrorPayload->identity_profile_not_found,
                status => $HTTP_NOT_FOUND,
            );
        }
        return $self->render(
            template => 'identity/profile_not_found',
            status   => $HTTP_NOT_FOUND,
        );
    }

    # A signed-in reader gets the id of the form that reports the member.
    my $page = $result->{profile} || {};
    $page->{report_command_id} =
      $self->session('user_id') ? $self->gp_id->uuid : q{};
    my $profile = $self->gp_identity_view_model->profile($page);

    if ( $self->_wants_json ) {
        return $self->render(
            json   => { profile => $profile },
            status => $HTTP_OK,
        );
    }

    return $self->render(
        template => 'identity/profile',
        profile  => $profile,
        status   => $HTTP_OK,
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Identity::Profile - Public member profile.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/u/:username')->to('Identity::Profile#profile');

=head1 DESCRIPTION

Renders a public-safe member profile page or JSON payload.

=head1 SUBROUTINES/METHODS

=head2 profile

Loads a visible public profile for the requested username.

=head1 DIAGNOSTICS

Missing profiles render C<404>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the profile reader helper registered during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Identity::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The profile page does not expose private or moderated content.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
