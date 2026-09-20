package GPForum::Controller::Identity::Settings;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use GPForum::Web::Access;
use Mojo::Base 'GPForum::Controller::Identity::Base';

our $VERSION = '0.001';

const my $HTTP_OK => 200;

sub set_locale {
    my ($self) = @_;

    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        return $self->_csrf_failure;
    }

    my $blocked = $self->_require_preference_command;
    if ($blocked) {
        return $blocked;
    }

    return $self->_commit_locale;
}

sub set_theme {
    my ($self) = @_;

    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        return $self->_csrf_failure;
    }

    my $blocked = $self->_require_preference_command;
    if ($blocked) {
        return $blocked;
    }

    return $self->_commit_theme;
}

sub _require_preference_command {
    my ($self) = @_;

    if ( !$self->current_user_id ) {
        return;
    }
    if ( length $self->command_id_param ) {
        return;
    }

    return $self->identity_bad_request;
}

sub _commit_locale {
    my ($self) = @_;

    my $locale = $self->requested_locale;
    my $result = $self->persist_locale_preference($locale);
    if ( $result && !$result->{ok} ) {
        return $self->identity_write_failure($result);
    }

    return $self->_locale_accepted($locale);
}

sub _commit_theme {
    my ($self) = @_;

    my $theme  = $self->requested_theme;
    my $result = $self->persist_theme_preference($theme);
    if ( $result && !$result->{ok} ) {
        return $self->identity_write_failure($result);
    }

    return $self->_theme_accepted($theme);
}

sub _locale_accepted {
    my ( $self, $locale ) = @_;

    $self->set_locale_cookie($locale);
    $self->stash( ui_locale => $locale );
    $self->flash( success => $self->t('locale.updated') );

    return $self->redirect_to(
        $self->safe_return_to( $self->param('return_to') ) );
}

sub _theme_accepted {
    my ( $self, $theme ) = @_;

    $self->set_theme_cookie($theme);
    $self->stash( ui_theme => $theme );
    $self->flash( success => $self->t('theme.updated') );

    return $self->redirect_to(
        $self->safe_return_to( $self->param('return_to') ) );
}

sub settings {
    my ($self) = @_;

    my $user_id = $self->current_user_id;
    if ( !$user_id ) {
        return $self->settings_unauthorized;
    }

    return $self->_render_settings($user_id);
}

sub update_settings {
    my ($self) = @_;

    my $blocked = $self->_settings_write_guard;
    if ($blocked) {
        return $blocked;
    }

    return $self->_save_settings;
}

sub _render_settings {
    my ( $self, $user_id ) = @_;

    my $payload = $self->_settings_payload($user_id);
    if ( !$payload ) {
        return $self->settings_system_failure;
    }

    return $self->render(
        template            => 'identity/settings',
        email_command_id    => $self->gp_id->uuid,
        password_command_id => $self->gp_id->uuid,
        settings_command_id => $self->gp_id->uuid,
        %{$payload},
        status => $HTTP_OK,
    );
}

sub _settings_write_guard {
    my ($self) = @_;

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

    return;
}

sub _save_settings {
    my ($self) = @_;

    my $failed = $self->_persist_settings;
    if ($failed) {
        return $failed;
    }

    $self->flash( success => $self->t('settings.saved') );
    return $self->redirect_to('settings');
}

sub _persist_settings {
    my ($self) = @_;

    my $result = $self->_notification_preference_result;
    if ( !$result->{ok} ) {
        return $self->_settings_write_failure($result);
    }

    $self->_apply_preference_update( $self->requested_locale,
        $self->requested_theme );
    return;
}

sub _notification_preference_result {
    my ($self) = @_;

    my $store = $self->gp_notification_preference_store;
    return $self->gp_notification_workflow->set_preferences(
        {
            command_id  => $self->command_id_param,
            preferences => $self->_notification_preference_input($store),
            user_id     => $self->current_user_id,
        }
    );
}

sub _settings_write_failure {
    my ( $self, $result ) = @_;

    if ( ( $result->{status} || q{} ) eq 'not_found' ) {
        $self->app->log->warn('notification preference update degraded');
        return $self->settings_system_failure;
    }

    return $self->identity_write_failure($result);
}

sub _apply_preference_update {
    my ( $self, $locale, $theme ) = @_;

    $self->stash( mint_preference_command => 1 );
    $self->persist_locale_preference($locale);
    $self->persist_theme_preference($theme);
    $self->set_locale_cookie($locale);
    $self->set_theme_cookie($theme);
    $self->stash( ui_locale => $locale, ui_theme => $theme );
    return;
}

sub _settings_payload {
    my ( $self, $user_id ) = @_;

    my $store       = $self->gp_notification_preference_store;
    my $preferences = eval { return $store->preferences_for_user($user_id); };
    if ( !$preferences ) {
        return;
    }

    return $self->gp_identity_view_model->settings_page(
        digest_frequency_options => $store->digest_frequency_options,
        locale_options           => $self->ui_locale_options,
        notification_preferences => $preferences,
        theme_options            => $self->ui_theme_options,
    );
}

sub _notification_preference_input {
    my ( $self, $store ) = @_;

    my @preferences;
    for my $channel ( @{ $store->channel_names } ) {
        push @preferences, $self->_channel_preference($channel);
    }

    return \@preferences;
}

sub _channel_preference {
    my ( $self, $channel ) = @_;

    my $enabled = $self->param( 'notification_' . $channel . '_enabled' );

    return {
        channel          => $channel,
        digest_frequency =>
          $self->param( 'notification_' . $channel . '_digest_frequency' ),
        enabled => $enabled ? 1 : 0,
    };
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
