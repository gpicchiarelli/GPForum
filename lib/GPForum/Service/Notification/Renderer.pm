# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Notification::Renderer;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Service::I18N;

our $VERSION = '0.001';

const my %KNOWN_NOTIFICATION_TYPE => map { $_ => 1 }
  qw(follow mention notification reply);

has i18n => sub { return GPForum::Service::I18N->new; };

sub render_inbox_item ( $self, $locale, $notification ) {
    my $type      = _notification_type($notification);
    my $variables = _notification_variables($notification);

    return {
        type_key   => $type,
        type_label => $self->i18n->translate(
            $locale, "notifications.type.$type", $variables
        ),
        title => $self->i18n->translate(
            $locale, "notifications.title.$type", $variables
        ),
        summary => $self->i18n->translate(
            $locale, "notifications.body.$type", $variables
        ),
        action_label => $self->i18n->translate(
            $locale, 'notifications.open_discussion', $variables
        ),
        email => $self->render_email( $locale, $notification ),
    };
}

sub render_email ( $self, $locale, $notification ) {
    my $type      = _notification_type($notification);
    my $variables = _notification_variables($notification);

    return {
        subject => $self->i18n->translate(
            $locale, "notifications.email_subject.$type", $variables
        ),
        text_body => $self->i18n->translate(
            $locale, "notifications.email_body.$type", $variables
        ),
    };
}

sub render_mention ( $self, $locale, $mention ) {
    my $variables = _mention_variables($mention);

    return {
        title =>
          $self->i18n->translate( $locale, 'mentions.title', $variables ),
        by_label =>
          $self->i18n->translate( $locale, 'mentions.by', $variables ),
        summary =>
          $self->i18n->translate( $locale, 'mentions.summary', $variables ),
        actor_label  => $variables->{actor},
        action_label =>
          $self->i18n->translate( $locale, 'mentions.open_discussion' ),
        email => {
            subject => $self->i18n->translate(
                $locale, 'mentions.email_subject', $variables
            ),
            text_body => $self->i18n->translate(
                $locale, 'mentions.email_body', $variables
            ),
        },
    };
}

sub _notification_type ($notification) {
    my $type = _key_fragment( $notification->{notification_type} );

    return exists $KNOWN_NOTIFICATION_TYPE{$type} ? $type : 'notification';
}

sub _notification_variables ($notification) {
    my $payload = $notification->{payload} || {};

    return {
        actor_id           => _value( $payload->{actor_id} ),
        mentioned_username => _value( $payload->{mentioned_username} ),
        post_id            => _value( $payload->{post_id} ),
        source_id          => _value( $notification->{source_id} ),
        source_type        => _value( $notification->{source_type} ),
        thread_id          => _value( $payload->{thread_id} ),
    };
}

sub _mention_variables ($mention) {
    return {
        actor       => _actor_label($mention),
        source_id   => _value( $mention->{source_id} ),
        source_type => _value( $mention->{source_type} ),
    };
}

sub _actor_label ($mention) {
    return $mention->{actor_profile_label}
      if defined $mention->{actor_profile_label}
      && length $mention->{actor_profile_label};
    return $mention->{actor_display_name}
      if defined $mention->{actor_display_name}
      && length $mention->{actor_display_name};
    return $mention->{actor_username}
      if defined $mention->{actor_username}
      && length $mention->{actor_username};
    return _value( $mention->{actor_id} );
}

sub _key_fragment ($value) {
    return q{} if !defined $value;

    $value = lc $value;
    $value =~ s/[^a-z0-9]+/_/gmsx;
    $value =~ s/\A_+//msx;
    $value =~ s/_+\z//msx;

    return $value;
}

sub _value ($value) {
    return defined $value ? "$value" : q{};
}

1;
