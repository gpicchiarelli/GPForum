# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Identity::Settings;

use Const::Fast;
use GPForum::Web::Access;
use Mojo::Base 'GPForum::Controller::Identity::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

sub set_locale ($self) {
    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        return $self->_csrf_failure;
    }

    my $blocked = $self->_require_preference_command;
    if ($blocked) {
        return $blocked;
    }

    my $locale = $self->requested_locale;
    my $result = $self->persist_locale_preference($locale);
    if ( $result && !$result->{ok} ) {
        return $self->identity_write_failure($result);
    }

    $self->set_locale_cookie($locale);
    $self->stash( ui_locale => $locale );
    $self->flash( success => $self->t('locale.updated') );
    return $self->redirect_to(
        $self->safe_return_to( $self->param('return_to') ) );
}

sub set_theme ($self) {
    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        return $self->_csrf_failure;
    }

    my $blocked = $self->_require_preference_command;
    if ($blocked) {
        return $blocked;
    }

    my $theme  = $self->requested_theme;
    my $result = $self->persist_theme_preference($theme);
    if ( $result && !$result->{ok} ) {
        return $self->identity_write_failure($result);
    }

    $self->set_theme_cookie($theme);
    $self->stash( ui_theme => $theme );
    $self->flash( success => $self->t('theme.updated') );
    return $self->redirect_to(
        $self->safe_return_to( $self->param('return_to') ) );
}

sub _require_preference_command ($self) {
    if ( !$self->current_user_id ) {
        return undef;
    }
    if ( length $self->command_id_param ) {
        return undef;
    }

    return $self->identity_bad_request;
}

sub settings ($self) {
    my $user_id = $self->current_user_id;
    if ( !$user_id ) {
        return $self->settings_unauthorized;
    }

    # The page shows the notification preferences: when they cannot be read
    # it answers 500.
    my $store = $self->gp_notification_preference_store;
    my $preferences;
    try {
        $preferences = $store->preferences_for_user($user_id);
    }
    catch ($error) {
        return $self->settings_system_failure;
    };

    return $self->render(
        template            => 'identity/settings',
        email_command_id    => $self->gp_id->uuid,
        password_command_id => $self->gp_id->uuid,
        settings_command_id => $self->gp_id->uuid,
        %{
            $self->gp_identity_view_model->settings_page(
                digest_frequency_options => $store->digest_frequency_options,
                locale_options           => $self->ui_locale_options,
                notification_preferences => $preferences,
                theme_options            => $self->ui_theme_options,
                timezone_options         => $self->_timezone_options,
            )
        },
        status => $HTTP_OK,
    );
}

sub update_settings ($self) {
    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        return $self->_csrf_failure;
    }

    my $user_id = $self->current_user_id;
    if ( !$user_id ) {
        return $self->settings_unauthorized;
    }
    if ( !$self->_identity_allowed('identity.settings') ) {
        return $self->_rate_limited;
    }

    my $result = $self->gp_notification_workflow->set_preferences(
        {
            command_id  => $self->command_id_param,
            preferences => $self->_notification_preference_input,
            user_id     => $user_id,
        }
    );
    if ( !$result->{ok} ) {
        if ( ( $result->{status} || q{} ) eq 'not_found' ) {
            $self->app->log->warn('notification preference update degraded');
            return $self->settings_system_failure;
        }
        return $self->identity_write_failure($result);
    }

    my $locale = $self->requested_locale;
    my $theme  = $self->requested_theme;
    $self->stash( mint_preference_command => 1 );
    $self->persist_locale_preference($locale);
    $self->persist_theme_preference($theme);
    $self->set_locale_cookie($locale);
    $self->set_theme_cookie($theme);
    $self->stash( ui_locale => $locale, ui_theme => $theme );
    $self->persist_timezone_preference( $self->requested_timezone );

    $self->flash( success => $self->t('settings.saved') );
    return $self->redirect_to('settings');
}

# The forum's default first -- what an empty choice means -- then every zone
# the time zone database knows, by name.
sub _timezone_options ($self) {
    my $formats = $self->i18n_service->formats;
    my $stored  = $self->session('preferred_timezone');
    my $chosen  = $formats->valid_time_zone($stored) ? $stored : q{};

    return [
        {
            current => length $chosen ? 0 : 1,
            label   => $self->t(
                'settings.timezone_default',
                { zone => $self->ui_default_timezone }
            ),
            value => q{},
        },
        map { { current => $_ eq $chosen ? 1 : 0, label => $_, value => $_, } }
          sort @{ $formats->time_zone_names },
    ];
}

sub _notification_preference_input ($self) {
    my @preferences;
    for my $channel (
        @{ $self->gp_notification_preference_store->channel_names } )
    {
        my $field = 'notification_' . $channel;
        push @preferences,
          {
            channel          => $channel,
            digest_frequency => $self->param( $field . '_digest_frequency' ),
            enabled          => $self->param( $field . '_enabled' ) ? 1 : 0,
          };
    }

    return \@preferences;
}

1;
__END__

=head1 NAME

GPForum::Controller::Identity::Settings - Locale, theme, and member settings.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/settings')->to('Identity::Settings#settings');

=head1 DESCRIPTION

Handles locale/theme cookies and the authenticated settings page.

=head1 SUBROUTINES/METHODS

=head2 set_locale

Updates the UI locale cookie and optional stored preference. Authenticated
writes require C<command_id>. HTML writes set a success flash.

=head2 set_theme

Updates the UI theme cookie and optional stored preference. Authenticated
writes require C<command_id>. HTML writes set a success flash.

=head2 settings

Renders the signed-in settings page.

=head2 update_settings

Persists notification, locale, and theme preferences. Notification
writes require C<command_id>. Locale and theme on this POST mint their
own keys.

=head1 DIAGNOSTICS

Unauthenticated settings requests redirect to login.

=head1 CONFIGURATION AND ENVIRONMENT

Uses identity and notification helpers registered during application
startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Identity::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Anonymous locale and theme posts still update cookies without a stored
user preference.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
