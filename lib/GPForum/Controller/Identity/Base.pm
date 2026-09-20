package GPForum::Controller::Identity::Base;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'Mojolicious::Controller';
use Time::HiRes qw(time);

use GPForum::Web::Access;
use GPForum::Web::ErrorPayload;
use GPForum::Web::IdentityAccess;
use Scalar::Util qw(blessed);

our $VERSION = '0.001';

const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_TOO_MANY     => 429;
const my $HTTP_UNAUTHORIZED => 401;

sub identity_access {
    return GPForum::Web::IdentityAccess->new;
}

sub identity_post_guard {
    my ( $self, $action ) = @_;

    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        return $self->_csrf_failure;
    }
    if ( !$self->_identity_allowed($action) ) {
        return $self->_rate_limited;
    }

    return;
}

sub current_user_id {
    my ($self) = @_;

    return GPForum::Web::Access->new->user_id($self);
}

sub request_address {
    my ($self) = @_;

    return $self->tx->remote_address || 'unknown';
}

sub command_id_param {
    my ($self) = @_;

    my $command_id = $self->_trim( $self->param('command_id') );
    if ( length $command_id ) {
        return $command_id;
    }

    return $self->_trim( $self->param('idempotency_key') );
}

sub requested_locale {
    my ($self) = @_;

    return $self->i18n_service->supported_locale( $self->param('locale') )
      || $self->ui_locale;
}

sub requested_theme {
    my ($self) = @_;

    my $theme = $self->param('theme');
    if ( $self->ui_theme_registry->supported($theme) ) {
        return $theme;
    }

    return $self->ui_theme_registry->default_theme;
}

sub persist_locale_preference {
    my ( $self, $locale ) = @_;

    my $user_id = $self->current_user_id;
    if ( !$self->_has_text($user_id) ) {
        return;
    }

    $self->session( preferred_locale => $locale );
    return $self->_store_preferred_locale( $user_id, $locale );
}

sub persist_theme_preference {
    my ( $self, $theme ) = @_;

    my $user_id = $self->current_user_id;
    if ( !$self->_has_text($user_id) ) {
        return;
    }

    $self->session( preferred_theme => $theme );
    return $self->_store_preferred_theme( $user_id, $theme );
}

sub login_preferred_locale {
    my ( $self, $authenticated ) = @_;

    my $from_user =
      $self->_authenticated_user_text( $authenticated, 'preferred_locale' );
    if ($from_user) {
        return $from_user;
    }

    my $from_cookie = $self->i18n_service->supported_locale(
        $self->cookie( $self->locale_cookie_name ) );
    if ($from_cookie) {
        return $from_cookie;
    }

    return $self->ui_locale;
}

sub login_preferred_theme {
    my ( $self, $authenticated ) = @_;

    my $authenticated_theme =
      $self->_authenticated_user_text( $authenticated, 'preferred_theme' );
    if ( $self->ui_theme_registry->supported($authenticated_theme) ) {
        return $authenticated_theme;
    }

    my $cookie_theme = $self->cookie( $self->theme_cookie_name );
    if ( $self->ui_theme_registry->supported($cookie_theme) ) {
        return $cookie_theme;
    }

    return $self->ui_theme;
}

sub _authenticated_user_text {
    my ( $self, $authenticated, $name ) = @_;

    if ( $self->_has_text( $authenticated->{$name} ) ) {
        return $authenticated->{$name};
    }

    return $self->_user_preference_text( $authenticated->{user}, $name );
}

sub set_locale_cookie {
    my ( $self, $locale ) = @_;

    if ( !$self->_has_text($locale) ) {
        return;
    }

    $self->cookie(
        $self->locale_cookie_name => $locale,
        $self->_preference_cookie_options,
    );
    return;
}

sub set_theme_cookie {
    my ( $self, $theme ) = @_;

    if ( !$self->_has_text($theme) ) {
        return;
    }

    $self->cookie(
        $self->theme_cookie_name => $theme,
        $self->_preference_cookie_options,
    );
    return;
}

sub locale_cookie_name {
    my ($self) = @_;

    return $self->identity_access->locale_cookie_name;
}

sub theme_cookie_name {
    my ($self) = @_;

    return $self->identity_access->theme_cookie_name;
}

sub safe_return_to {
    my ( $self, $return_to ) = @_;

    if ( !$self->_safe_relative_path($return_to) ) {
        return q{/};
    }

    return $return_to;
}

sub settings_unauthorized {
    my ($self) = @_;

    if ( $self->_wants_json ) {
        return $self->render(
            json   => GPForum::Web::ErrorPayload->unauthorized,
            status => $HTTP_UNAUTHORIZED,
        );
    }

    $self->flash( error => $self->t('settings.login_required') );
    return $self->redirect_to('login');
}

sub settings_system_failure {
    my ($self) = @_;

    return $self->identity_access->system_failure($self);
}

sub identity_bad_request {
    my ($self) = @_;

    return $self->identity_access->bad_request($self);
}

sub identity_system_failure {
    my ($self) = @_;

    return $self->settings_system_failure;
}

sub identity_write_failure {
    my ( $self, $result ) = @_;

    if ( ( $result->{status} || q{} ) eq 'failed' ) {
        return $self->identity_unavailable;
    }

    return $self->identity_bad_request;
}

sub identity_unavailable {
    my ($self) = @_;

    return $self->identity_access->service_unavailable($self);
}

sub _identity_allowed {
    my ( $self, $action ) = @_;

    my $decision = $self->gp_rate_limiter->check(
        $self->identity_access->write_rate_input(
            {
                action   => $action,
                actor_id => $self->_identity_actor,
            }
        )
    );

    return $decision->{ok};
}

sub _identity_actor {
    my ($self) = @_;

    return $self->current_user_id || $self->request_address;
}

sub _rate_limited {
    my ($self) = @_;

    $self->_record_security_event(
        'rate_limit_hit',
        {
            status => $HTTP_TOO_MANY,
        }
    );

    return $self->identity_access->rate_limited($self);
}

sub _csrf_failure {
    my ($self) = @_;

    $self->_record_security_event(
        'csrf_failure',
        {
            status => $HTTP_FORBIDDEN,
        }
    );

    return $self->identity_access->csrf_failure($self);
}

sub _wants_json {
    my ($self) = @_;

    return GPForum::Web::Access->new->wants_json($self);
}

sub _store_preferred_locale {
    my ( $self, $user_id, $locale ) = @_;

    my $result = $self->gp_identity_workflow->update_preferred_locale(
        {
            command_id       => $self->_preference_command_id,
            preferred_locale => $locale,
            user_id          => $user_id,
        }
    );
    if ( $result->{ok} ) {
        return $result;
    }

    $self->app->log->warn('locale preference update degraded');
    return $result;
}

sub _store_preferred_theme {
    my ( $self, $user_id, $theme ) = @_;

    my $result = $self->gp_identity_workflow->update_preferred_theme(
        {
            command_id      => $self->_preference_command_id,
            preferred_theme => $theme,
            user_id         => $user_id,
        }
    );
    if ( $result->{ok} ) {
        return $result;
    }

    $self->app->log->warn('theme preference update degraded');
    return $result;
}

sub _preference_command_id {
    my ($self) = @_;

    if ( $self->stash('mint_preference_command') ) {
        return $self->gp_id->uuid;
    }

    my $command_id = $self->command_id_param;
    if ( length $command_id ) {
        return $command_id;
    }

    return $self->gp_id->uuid;
}

sub _user_preference_text {
    my ( $self, $user, $name ) = @_;

    if ( ref $user eq 'HASH' && $self->_has_text( $user->{$name} ) ) {
        return $user->{$name};
    }

    return $self->_row_column( $user, $name );
}

sub _row_column {
    my ( $self, $row, $name ) = @_;

    if ( !$self->_has_column_reader($row) ) {
        return;
    }

    my $value = $row->get_column($name);
    if ( !defined $value ) {
        return;
    }

    return $value;
}

sub _has_column_reader {
    my ( undef, $row ) = @_;

    if ( !$row ) {
        return 0;
    }
    if ( !blessed($row) ) {
        return 0;
    }

    return $row->can('get_column') ? 1 : 0;
}

sub _preference_cookie_options {
    my ($self) = @_;

    return $self->identity_access->preference_cookie_options(time);
}

sub _has_text {
    my ( undef, $value ) = @_;

    return GPForum::Web::Access->new->has_text($value);
}

sub _safe_relative_path {
    my ( $self, $return_to ) = @_;

    if ( !$self->_has_text($return_to) ) {
        return 0;
    }
    if ( $return_to !~ m{\A/}msx ) {
        return 0;
    }
    if ( $return_to =~ m{\A//}msx ) {
        return 0;
    }
    if ( $return_to =~ /[\r\n]/msx ) {
        return 0;
    }

    return 1;
}

sub _record_security_event {
    my ( $self, $event_type, $metadata ) = @_;

    return $self->gp_security_telemetry->record(
        $event_type,
        {
            %{$metadata}, route => $self->_current_route_name,
        }
    );
}

sub _current_route_name {
    my ($self) = @_;

    my $route = eval { return $self->current_route; };
    if ($route) {
        return $route;
    }

    return 'unknown';
}

sub _trim {
    my ( undef, $value ) = @_;

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

GPForum::Controller::Identity::Base - Shared identity HTTP helpers.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use Mojo::Base 'GPForum::Controller::Identity::Base';

=head1 DESCRIPTION

Owns CSRF, telemetry, session user, and error helpers used by identity
session, password, email, settings, and profile controllers. Identity text,
JSON error contracts, identity_http rate hashes, and preference-cookie names
live in L<GPForum::Web::IdentityAccess>. Cookie writes stay here.

=head1 SUBROUTINES/METHODS

=head2 identity_post_guard

Rejects invalid CSRF tokens and rate-limited identity writes.

=head2 command_id_param

Reads a posted C<command_id>, falling back to C<idempotency_key>.

=head2 identity_write_failure

Maps a failed identity store write to HTTP 503 and other non-ok results to
HTTP 400.

=head2 persist_locale_preference

Stores an authenticated locale through C<Identity::Workflow> and the cookie
session.

=head2 persist_theme_preference

Stores an authenticated theme through C<Identity::Workflow> and the cookie
session.

=head2 login_preferred_locale

Resolves locale for cookie-session rotation from the authenticated user,
cookie, or current UI locale.

=head2 login_preferred_theme

Resolves theme for cookie-session rotation from the authenticated user,
cookie, or current UI theme.

=head1 DIAGNOSTICS

HTTP errors are rendered as JSON or text depending on the request.

=head1 CONFIGURATION AND ENVIRONMENT

Uses identity helpers registered during application startup.

=head1 DEPENDENCIES

Uses L<Mojolicious::Controller>, L<GPForum::Web::Access>, and L<Scalar::Util>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Helpers are HTTP-oriented and must not talk to DBIx::Class resultsets.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
