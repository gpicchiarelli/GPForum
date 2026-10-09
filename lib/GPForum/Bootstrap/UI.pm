# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Bootstrap::UI;

use v5.40;

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
use GPForum::Web::AssetManifest;
use GPForum::Web::IdentityAccess;
use GPForum::Web::RenderPolicy;
use GPForum::X::Argument;
use Mojo::ByteStream;
use Mojo::Util qw(xml_escape);

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
    _register_translation_helpers( $application, $default_timezone, $i18n );
    _register_presentation_helpers($application);
    _register_theme_helpers( $application, $theme_cookie );
    _register_asset_helpers($application);

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
    my ( $application, $default_timezone, $i18n ) = @_;

    # A page asks for some 360 messages, almost all plain keys with nothing to
    # interpolate. Those are answered from the service's resolved table in
    # one step; a key not resolved yet, or a message with variables, goes
    # through translate as before, which resolves it for the next time.
    my $translate = sub {
        my ( $controller, $key, $variables ) = @_;

        my $locale = $controller->stash->{ui_locale};
        if ( !defined $locale || !length $locale ) {
            $locale = $controller->ui_locale;
        }
        if ( !$variables || !%{$variables} ) {
            my $message = $i18n->resolved_messages->{$locale}{$key};
            return $message
              if defined $message && index( $message, '{' ) < 0;
        }

        return $i18n->translate( $locale, $key, $variables || {} );
    };
    $application->helper( i18n => $translate );
    $application->helper( t    => $translate );
    $application->helper( l    => $translate );
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
    $application->helper( ui_timestamp          => \&_time_element );
    $application->helper( ui_path               => _route_path_helper() );
    $application->helper( ui_thread_breadcrumbs => \&_thread_breadcrumbs );
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

# One timestamp as a <time> element: the instant in datetime, the absolute
# time in the reader's zone in title (on hover, and to assistive technology),
# and as text a relative phrase ("3 minutes ago") or the absolute time.
#
# A signed-in reader's page is rendered for them alone and is not cached, so
# the phrase is true when it is sent. An anonymous reader's page may come
# from the public page cache, and a browser or proxy may keep it for a
# max-age and a stale-while-revalidate more: the phrase would go stale while
# it is kept, and would change the page's ETag on every render. It shows the
# absolute time, which no cache can make wrong. Signed in or not is the
# cache's own test (Web::PublicCacheAccess). See docs/i18n.md.
#
# An anonymous page is also in the forum's zone, never the session's: a
# member whose session has run out is signed out at the door but still
# carries their zone for that request, and the cache key does not name the
# zone, so their page would be served to every visitor in their time.
#
# Takes the timestamp and, optionally, the text shown when there is none. A
# value the formatter cannot read is shown as it is. The components/timestamp
# partial renders this; a page that shows many times calls it directly, since
# a partial costs a render of its own.
sub _time_element ( $controller, $at, $missing = undef ) {
    if ( !defined $at || !length $at ) {
        return Mojo::ByteStream->new( xml_escape( $missing // q{} ) );
    }

    my $signed_in = $controller->session('user_id');
    my $when      = $controller->i18n_service->formats->relative_datetime(
        $controller->ui_locale,
        $at,
        $signed_in
        ? $controller->ui_timezone
        : $controller->ui_default_timezone
    );
    if ( !$when ) {
        return Mojo::ByteStream->new( xml_escape($at) );
    }

    my $text = $when->{date};
    if ( !$signed_in ) {
        $text = $when->{absolute};
    }
    elsif ( $when->{phrase} ) {
        $text = $controller->tc( $when->{phrase}, $when->{count} );
    }

    return Mojo::ByteStream->new(
        sprintf '<time datetime="%s" title="%s">%s</time>',
        map { xml_escape($_) } $when->{datetime},
        $when->{absolute}, $text
    );
}

# The path of a named route, as url_for would write it, without the URL
# object url_for builds and parses on the way: a thread page writes sixty
# of them, one for each post's author and each of its actions, and they
# were a tenth of its time. The base path is read once per request, for a
# forum served under a prefix.
# The path a named route writes for its values: the route's base path, read
# once per request, and the route's own path. Mojolicious renders that by
# walking the route's chain of parents and each pattern's tokens on every
# call, and the thread page asks for 64 paths. Each route is read once into
# a writer -- its text, slashes and placeholder names in order -- and a path
# is then the join of those. A route with an optional placeholder (one with
# a default), or a call that names a format, is rendered by Mojolicious:
# the writer does not reproduce what they leave out.
sub _route_path_helper {
    my %writers;

    return sub {
        my ( $controller, $name, %values ) = @_;

        my $base = $controller->stash('ui_base_path');
        if ( !defined $base ) {
            my $url = $controller->req->url;
            $base = $url->base->path->to_string;
            $base =~ s{/\z}{}msx;
            $controller->stash( ui_base_path => $base );
        }

        my $route = $controller->app->routes->lookup($name)
          // GPForum::X::Argument->throw( message => "unknown route: $name" );
        my $writer = $writers{$name} //= _path_writer($route);
        return $base . $route->render( \%values )
          if !$writer || exists $values{format};

        return $base
          . (
            join( q{},
                map { ref $_ ? $values{ ${$_} } // q{} : $_ } @{$writer} )
              || q{/}
          );
    };
}

# A route's path as its chain of patterns writes it when every placeholder
# is given and none is optional: each pattern's text and placeholders, the
# slashes between them, and not the slashes after its last part, which
# Mojolicious leaves out. Undef for a route with a defaulted placeholder.
sub _path_writer ($route) {
    my @chain = ($route);
    while ( my $parent = $chain[0]->parent ) {
        unshift @chain, $parent;
    }

    my @parts;
    for my $link (@chain) {
        my $defaults = $link->pattern->defaults;
        my @kept     = @{ $link->pattern->tree };
        while ( @kept && $kept[-1][0] eq 'slash' ) {
            pop @kept;
        }
        for my $token (@kept) {
            my ( $kind, $value ) = @{$token};
            if ( $kind eq 'text' ) {
                push @parts, $value;
            }
            elsif ( $kind eq 'slash' ) {
                push @parts, q{/};
            }
            else {
                my $placeholder = $value->[0];
                return undef if defined $defaults->{$placeholder};
                push @parts, \$placeholder;
            }
        }
    }

    return _joined_text( \@parts );
}

# Adjacent text parts as one, so a path is the join of as few parts as it
# has placeholders.
sub _joined_text ($parts) {
    my @joined;
    for my $part ( @{$parts} ) {
        if ( !ref $part && @joined && !ref $joined[-1] ) {
            $joined[-1] .= $part;
            next;
        }
        push @joined, $part;
    }

    return \@joined;
}

# Where a thread page stands: home, the categories, its category, itself.
# The page sets them for the layout and the fragment sends them again when
# a write changed the title or the category.
sub _thread_breadcrumbs ( $controller, $thread ) {
    return [
        {
            current => 0,
            label   => $controller->i18n('nav.home'),
            url     => $controller->ui_path('home'),
        },
        {
            current => 0,
            label   => $controller->i18n('nav.categories'),
            url     => $controller->ui_path('categories'),
        },
        {
            current => 0,
            label   => $thread->{category_title}
              // $controller->i18n('forum.back_to_category'),
            url => $controller->ui_path(
                'category', category_id => $thread->{category_id}
            ),
        },
        { current => 1, label => $thread->{title} },
    ];
}

sub _register_presentation_helpers {
    my ($application) = @_;

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
                degraded  => 'warning',
                done      => 'success',
                failed    => 'danger',
                ok        => 'success',
                open      => 'warning',
                pending   => 'warning',
                rejected  => 'danger',
                resolved  => 'success',
                sent      => 'success',
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

            return [ map { _locale_option( $controller, $_ ) }
                  @{ $controller->i18n_service->supported_locales } ];
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

# The theme a request renders in -- the session's choice, then the cookie,
# then the default -- and what the layout reads from it.
sub _register_theme_helpers {
    my ( $application, $theme_cookie ) = @_;

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

    return;
}

# 7.7: the layout names each static file by the digest of its bytes, and a
# response for that exact URL may be cached for a year. The files are read
# now, while the application starts (after Core has set the static paths),
# so Hypnotoad's workers share the digests and no request reads a file to
# name it.
sub _register_asset_helpers ($application) {
    my $asset_manifest = GPForum::Web::AssetManifest->new(
        roots => [ @{ $application->static->paths } ] );
    $asset_manifest->files;

    # A page names four assets, and each URL built a URL object on its base
    # and parsed the path. The files are digested once per process, so the
    # URL is written once per base path and name, and is a string after.
    my %urls;
    $application->helper(
        ui_asset_url => sub {
            my ( $controller, $name ) = @_;

            my $base = $controller->stash('ui_base_path');
            if ( !defined $base ) {
                my $url = $controller->req->url;
                $base = $url->base->path->to_string;
            }

            return $urls{"$base\0$name"} //=
              $asset_manifest->asset_url( $controller, $name )->to_string;
        }
    );
    $application->hook(
        after_static => sub {
            my ($controller) = @_;

            $asset_manifest->apply($controller);
        }
    );

    return;
}

sub _ui_breadcrumbs ($controller) {
    my $route = _current_route_name($controller);
    return [] if !defined $route || $route eq 'home' || $route eq 'unknown';

    my %route_key_for = (
        admin_audit            => 'nav.admin',
        admin_categories       => 'nav.admin',
        admin_dashboard        => 'nav.admin',
        admin_jobs             => 'nav.admin',
        admin_roles            => 'nav.admin',
        admin_settings         => 'nav.admin',
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
        privacy_dashboard      => 'nav.your_data',
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

sub _locale_option ( $controller, $locale ) {
    my $metadata = $controller->i18n_service->locale_metadata($locale);

    return {
        current     => $locale eq $controller->ui_locale ? 1 : 0,
        locale      => $locale,
        native_name => $metadata->{native_name},
    };
}

sub _current_route_name ($controller) {
    return 'unknown' if !$controller->match   || !$controller->match->endpoint;
    return $controller->match->endpoint->name || 'unknown';
}

sub _ui_label_key_fragment ($value) {
    my $fragment = lc $value;
    $fragment =~ s/[^[:lower:][:digit:]]+/_/gmsxa;
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
