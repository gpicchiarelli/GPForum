# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Bootstrap::UI;

use strict;
use warnings;
use feature 'signatures';

use GPForum::Theme::Registry;
use GPForum::View::Presenter;
use GPForum::ViewModel::Admin::Presenter;
use GPForum::ViewModel::Attachment::Presenter;
use GPForum::ViewModel::Community::Presenter;
use GPForum::ViewModel::Discovery::Presenter;
use GPForum::ViewModel::Forum::Presenter;
use GPForum::ViewModel::Identity::Presenter;
use GPForum::ViewModel::Moderation::Presenter;
use GPForum::ViewModel::Notifications::Presenter;
use GPForum::ViewModel::Privacy::Presenter;
use GPForum::Web::IdentityAccess;
use GPForum::Web::RenderPolicy;

our $VERSION = '0.001';

sub register {
    my ( undef, %input ) = @_;

    my $application = $input{application};
    my $i18n        = $input{i18n};

    my $identity_access = GPForum::Web::IdentityAccess->new;
    my $locale_cookie   = $identity_access->locale_cookie_name;
    my $theme_cookie    = $identity_access->theme_cookie_name;
    my $presenter       = GPForum::View::Presenter->new;
    my $render_policy   = GPForum::Web::RenderPolicy->new;
    my $theme_registry  = GPForum::Theme::Registry->new(
        configured_default_theme => $input{default_theme}, );
    my $default_timezone      = $input{default_timezone} || 'UTC';
    my $admin_view_model      = GPForum::ViewModel::Admin::Presenter->new;
    my $attachment_view_model = GPForum::ViewModel::Attachment::Presenter->new;
    my $community_view_model  = GPForum::ViewModel::Community::Presenter->new;
    my $discovery_view_model  = GPForum::ViewModel::Discovery::Presenter->new;
    my $forum_view_model      = GPForum::ViewModel::Forum::Presenter->new;
    my $identity_view_model   = GPForum::ViewModel::Identity::Presenter->new;
    my $moderation_view_model = GPForum::ViewModel::Moderation::Presenter->new;
    my $notifications_view_model =
      GPForum::ViewModel::Notifications::Presenter->new;
    my $privacy_view_model = GPForum::ViewModel::Privacy::Presenter->new;

    $application->helper( i18n_service     => sub { return $i18n; } );
    $application->helper( ui_render_policy => sub { return $render_policy; } );
    $application->helper( ui_presenter     => sub { return $presenter; } );
    $application->helper(
        ui_theme_registry => sub { return $theme_registry; } );
    $application->helper(
        gp_admin_view_model => sub { return $admin_view_model; } );
    $application->helper(
        gp_attachment_view_model => sub { return $attachment_view_model; } );
    $application->helper(
        gp_community_view_model => sub { return $community_view_model; } );
    $application->helper(
        gp_discovery_view_model => sub { return $discovery_view_model; } );
    $application->helper(
        gp_forum_view_model => sub { return $forum_view_model; } );
    $application->helper(
        gp_identity_view_model => sub { return $identity_view_model; } );
    $application->helper(
        gp_moderation_view_model => sub { return $moderation_view_model; } );
    $application->helper(
        gp_notifications_view_model => sub { return $notifications_view_model; }
    );
    $application->helper(
        gp_privacy_view_model => sub { return $privacy_view_model; } );
    $application->helper(
        ui_locale => sub {
            my ($controller) = @_;

            my $cached_locale = $controller->stash('ui_locale');
            return $cached_locale
              if defined $cached_locale && length $cached_locale;

            my $locale =
              $controller->i18n_service->supported_locale(
                $controller->session('preferred_locale') )
              || $controller->i18n_service->supported_locale(
                $controller->cookie($locale_cookie) )
              || $controller->i18n_service->negotiate(
                $controller->req->headers->header('Accept-Language') || q{} );
            $controller->stash( ui_locale => $locale );

            return $locale;
        }
    );
    _register_translation_helpers( $application, $default_timezone );
    _register_presentation_helpers( $application, $theme_cookie );

    $application->hook(
        after_dispatch => sub {
            my ($controller) = @_;

            $controller->res->headers->header(
                'Content-Language' => $controller->ui_locale );
        }
    );

    return;
}

sub _register_translation_helpers {
    my ( $application, $default_timezone ) = @_;

    $application->helper(
        i18n => sub {
            my ( $controller, $key, $variables ) = @_;

            return $controller->i18n_service->translate( $controller->ui_locale,
                $key, $variables || {},
            );
        }
    );
    $application->helper(
        t => sub {
            my ( $controller, $key, $variables ) = @_;

            return $controller->i18n( $key, $variables || {} );
        }
    );
    $application->helper(
        l => sub {
            my ( $controller, $key, $variables ) = @_;

            return $controller->i18n( $key, $variables || {} );
        }
    );

    # The formatting layer existed, was documented as live, and no template
    # used it -- twenty-plus surfaces printed the raw database timestamp as
    # visible text. These are the helpers that connect it. The raw value is
    # returned unchanged when it cannot be parsed, so a surface never loses
    # information because the formatter did not recognise a shape.
    # 9.3: a member's own zone when they chose one, otherwise the forum's
    # (GPFORUM_DEFAULT_TIMEZONE). A stored name the zone database no longer
    # knows falls back to the forum's rather than failing the page.
    $application->helper(
        ui_timezone => sub {
            my ($controller) = @_;

            my $cached = $controller->stash('ui_timezone');
            return $cached if defined $cached;

            my $chosen = $controller->session('preferred_timezone');
            my $zone =
                $controller->i18n_service->formats->valid_time_zone($chosen)
              ? $chosen
              : $default_timezone;
            $controller->stash( ui_timezone => $zone );

            return $zone;
        }
    );
    $application->helper(
        ui_default_timezone => sub { return $default_timezone; } );
    $application->helper(
        dt => sub {
            my ( $controller, $value ) = @_;

            return $controller->i18n_service->formats->format_datetime(
                $controller->ui_locale, $value, $controller->ui_timezone )
              // $value;
        }
    );
    $application->helper(
        d => sub {
            my ( $controller, $value ) = @_;

            return $controller->i18n_service->formats->format_date(
                $controller->ui_locale, $value, $controller->ui_timezone )
              // $value;
        }
    );
    $application->helper(
        num => sub {
            my ( $controller, $value ) = @_;

            return $controller->i18n_service->formats->format_number(
                $controller->ui_locale, $value ) // $value;
        }
    );
    $application->helper(
        tc => sub {
            my ( $controller, $key, $count, $variables ) = @_;

            return $controller->i18n_service->translate_count(
                $controller->ui_locale, $key,
                $count     || 0,
                $variables || {},
            );
        }
    );

    return;
}

sub _register_presentation_helpers {
    my ( $application, $theme_cookie ) = @_;

    $application->helper(
        ui_command_id => sub {
            my ($controller) = @_;

            return $controller->gp_id->uuid;
        }
    );
    $application->helper(
        ui_label => sub {
            my ( $controller, $namespace, $value ) = @_;

            return q{} if !defined $value || !length $value;

            my $label_key = $namespace . q{.} . _ui_label_key_fragment($value);
            return $controller->t($label_key)
              if $controller->i18n_service->has_key( $controller->ui_locale,
                $label_key );

            return $value;
        }
    );
    $application->helper(
        ui_tone => sub {
            my ( undef, @arguments ) = @_;

            my %tone_for = (
                active    => 'success',
                behind    => 'warning',
                cancelled => 'neutral',
                completed => 'success',
                current   => 'success',
                done      => 'success',
                failed    => 'danger',
                ok        => 'success',
                open      => 'warning',
                pending   => 'warning',
                rejected  => 'danger',
                resolved  => 'success',
                suspended => 'danger',
                triaged   => 'warning',
            );
            my $value = @arguments > 1 ? $arguments[1] : $arguments[0];
            my $key   = defined $value ? lc $value     : q{};

            return $tone_for{$key} || 'neutral';
        }
    );
    $application->helper(
        ui_action => sub {
            my ( $controller, %input ) = @_;

            return $controller->ui_presenter->action(%input);
        }
    );
    $application->helper(
        ui_actions => sub {
            my ( $controller, @actions ) = @_;

            return $controller->ui_presenter->actions(@actions);
        }
    );
    $application->helper(
        ui_next_page => sub {
            my ( $controller, %input ) = @_;

            return $controller->ui_presenter->next_page(%input);
        }
    );
    $application->helper(
        ui_badge => sub {
            my ( $controller, $namespace, $value ) = @_;

            return $controller->ui_presenter->badge(
                label => $controller->ui_label( $namespace, $value ),
                tone  => $controller->ui_tone($value),
            );
        }
    );
    $application->helper(
        ui_direction => sub {
            my ($controller) = @_;

            return $controller->i18n_service->direction(
                $controller->ui_locale );
        }
    );
    $application->helper(
        ui_locale_metadata => sub {
            my ($controller) = @_;

            return $controller->i18n_service->locale_metadata(
                $controller->ui_locale );
        }
    );
    $application->helper(
        ui_typography_class => sub {
            my ($controller) = @_;

            return $controller->ui_locale_metadata->{typography_class};
        }
    );
    $application->helper(
        ui_date => sub {
            my ( $controller, $epoch ) = @_;

            return $controller->i18n_service->format_date(
                $controller->ui_locale, $epoch, $controller->ui_timezone );
        }
    );
    $application->helper(
        ui_time => sub {
            my ( $controller, $epoch ) = @_;

            return $controller->i18n_service->format_time(
                $controller->ui_locale, $epoch, $controller->ui_timezone );
        }
    );
    $application->helper(
        ui_datetime => sub {
            my ( $controller, $epoch ) = @_;

            return $controller->i18n_service->format_datetime(
                $controller->ui_locale, $epoch, $controller->ui_timezone );
        }
    );
    $application->helper(
        ui_number => sub {
            my ( $controller, $number ) = @_;

            return $controller->i18n_service->format_number(
                $controller->ui_locale, $number );
        }
    );
    $application->helper(
        ui_theme => sub {
            my ($controller) = @_;

            my $cached_theme = $controller->stash('ui_theme');
            return $cached_theme
              if defined $cached_theme && length $cached_theme;

            my $requested_theme = $controller->session('preferred_theme')
              || $controller->cookie($theme_cookie);
            my $theme =
                $controller->ui_theme_registry->supported($requested_theme)
              ? $requested_theme
              : $controller->ui_theme_registry->default_theme;
            $controller->stash( ui_theme => $theme );

            return $theme;
        }
    );
    $application->helper(
        ui_theme_metadata => sub {
            my ($controller) = @_;

            return $controller->ui_theme_registry->theme(
                $controller->ui_theme );
        }
    );
    $application->helper(
        ui_theme_color => sub {
            my ($controller) = @_;

            return $controller->ui_theme_registry->theme_color(
                $controller->ui_theme );
        }
    );
    $application->helper(
        ui_theme_color_scheme => sub {
            my ($controller) = @_;

            return $controller->ui_theme_registry->color_scheme(
                $controller->ui_theme );
        }
    );
    $application->helper(
        ui_theme_options => sub {
            my ($controller) = @_;

            my $options = $controller->ui_theme_registry->theme_options(
                $controller->ui_theme );
            for my $option ( @{$options} ) {
                $option->{label} = $controller->t( $option->{label_key} );
            }

            return $options;
        }
    );
    $application->helper(
        ui_trusted_html => sub {
            my ( $controller, $html, $context ) = @_;

            return $controller->ui_render_policy->trusted_html(
                context => $context,
                html    => $html,
            );
        }
    );
    $application->helper(
        ui_attr => sub {
            my ( $controller, %input ) = @_;

            return $controller->ui_render_policy->attribute(%input);
        }
    );
    $application->helper(
        ui_locale_options => sub {
            my ($controller) = @_;

            return [
                map {
                    my $metadata =
                      $controller->i18n_service->locale_metadata($_);
                    {
                        current     => $_ eq $controller->ui_locale ? 1 : 0,
                        locale      => $_,
                        native_name => $metadata->{native_name},
                    }
                } @{ $controller->i18n_service->supported_locales }
            ];
        }
    );
    $application->helper(
        ui_return_to => sub {
            my ($controller) = @_;

            my $return_to = $controller->req->url->path_query;
            return
              defined $return_to && length $return_to ? "$return_to" : q{/};
        }
    );
    $application->helper(
        ui_breadcrumbs => sub {
            my ($controller) = @_;

            return _ui_breadcrumbs($controller);
        }
    );
    $application->helper(
        ui_flash_messages => sub {
            my ($controller) = @_;

            return _ui_flash_messages($controller);
        }
    );

    return;
}

sub _ui_breadcrumbs ($controller) {
    my $route = _current_route_name($controller);
    return [] if !defined $route || $route eq 'home' || $route eq 'unknown';

    my %route_key_for = (
        admin_audit            => 'nav.admin',
        admin_dashboard        => 'nav.admin',
        admin_jobs             => 'nav.admin',
        admin_roles            => 'nav.admin',
        admin_status           => 'nav.admin',
        admin_user_roles       => 'nav.admin',
        admin_users            => 'nav.admin',
        bookmarks              => 'nav.bookmarks',
        categories             => 'nav.categories',
        category               => 'nav.categories',
        feed                   => 'nav.feed',
        forum_search           => 'nav.search',
        legal_cookies          => 'legal.cookies',
        legal_privacy          => 'legal.privacy',
        legal_terms            => 'legal.terms',
        login                  => 'auth.login',
        mentions               => 'nav.mentions',
        moderation_actions     => 'nav.moderation',
        moderation_reports     => 'nav.moderation',
        moderation_suspensions => 'nav.moderation',
        new_thread             => 'nav.start_thread',
        notifications          => 'nav.notifications',
        privacy_dashboard      => 'nav.privacy',
        privacy_review         => 'nav.privacy',
        profile                => 'nav.profile',
        register               => 'auth.register',
        settings               => 'nav.settings',
        thread                 => 'nav.categories',
        thread_canonical       => 'nav.categories',
    );

    my $key = $route_key_for{$route};
    return [] if !defined $key;

    return [
        {
            current => 0,
            label   => $controller->t('nav.home'),
            url     => $controller->url_for('home')->to_string,
        },
        {
            current => 1,
            label   => $controller->t($key),
        },
    ];
}

sub _current_route_name ($controller) {
    return 'unknown' if !$controller->match   || !$controller->match->endpoint;
    return $controller->match->endpoint->name || 'unknown';
}

sub _ui_label_key_fragment ($value) {
    my $fragment = lc $value;
    $fragment =~ s/[^a-z0-9]+/_/gmsx;
    $fragment =~ s/\A _+//gmsx;
    $fragment =~ s/_+ \z//gmsx;

    return $fragment || 'unknown';
}

sub _ui_flash_messages ($controller) {
    my @messages;
    for my $type (qw(success notice warning error)) {
        my $message = $controller->flash($type);
        next if !defined $message || !length $message;
        push @messages,
          {
            message => $message,
            type    => $type,
          };
    }

    return \@messages;
}

1;
