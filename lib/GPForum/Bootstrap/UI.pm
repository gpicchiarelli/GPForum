package GPForum::Bootstrap::UI;

use strict;
use warnings;

use GPForum::View::Presenter;

our $VERSION = '0.001';

sub register {
    my ( undef, %input ) = @_;

    my $application = $input{application};
    my $i18n        = $input{i18n};

    my $locale_cookie = 'gpforum_locale';
    my $presenter     = GPForum::View::Presenter->new;

    $application->helper( i18n_service => sub { return $i18n; } );
    $application->helper( ui_presenter => sub { return $presenter; } );
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
    _register_translation_helpers($application);
    _register_presentation_helpers($application);

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
    my ($application) = @_;

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
    my ($application) = @_;

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
                cancelled => 'neutral',
                completed => 'success',
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
                $controller->ui_locale, $epoch );
        }
    );
    $application->helper(
        ui_time => sub {
            my ( $controller, $epoch ) = @_;

            return $controller->i18n_service->format_time(
                $controller->ui_locale, $epoch );
        }
    );
    $application->helper(
        ui_datetime => sub {
            my ( $controller, $epoch ) = @_;

            return $controller->i18n_service->format_datetime(
                $controller->ui_locale, $epoch );
        }
    );
    $application->helper(
        ui_number => sub {
            my ( $controller, $number ) = @_;

            return $controller->i18n_service->format_number(
                $controller->ui_locale, $number );
        }
    );
    $application->helper( ui_theme_color => sub { return '#f8f6ef'; } );
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

sub _ui_breadcrumbs {
    my ($controller) = @_;

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

sub _current_route_name {
    my ($controller) = @_;

    return 'unknown' if !$controller->match   || !$controller->match->endpoint;
    return $controller->match->endpoint->name || 'unknown';
}

sub _ui_label_key_fragment {
    my ($value) = @_;

    my $fragment = lc $value;
    $fragment =~ s/[^a-z0-9]+/_/gmsx;
    $fragment =~ s/\A _+//gmsx;
    $fragment =~ s/_+ \z//gmsx;

    return $fragment || 'unknown';
}

sub _ui_flash_messages {
    my ($controller) = @_;

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
