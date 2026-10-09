# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::ChannelAuthorizer;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

const my $THREAD_PREFIX       => 'thread';
const my $NOTIFICATION_PREFIX => 'notifications';

# No presence family: nothing published to it, so any user could subscribe to
# presence:<anything> and receive nothing. A cluster-wide presence would need
# a shared registry, which ADR 0067 rules out; a node-local one would show
# each viewer a different forum.
const my %SUPPORTED_CHANNELS => map { $_ => 1 }
  qw(thread notifications moderation admin feed);

has permission_engine => undef;    # optional: all channels forbidden without it

sub authorize ( $self, $actor, $channel, $context ) {
    my $parsed = parse_channel($channel);
    return { ok => 0, reason => 'malformed_channel' } if !$parsed;
    return { ok => 0, reason => 'unknown_channel' }
      if !exists $SUPPORTED_CHANNELS{ $parsed->{type} };
    return { ok => 0, reason => 'authentication_required' }
      if !_user_id($actor);

    return $self->_authorize_notifications( $actor, $parsed )
      if $parsed->{type} eq $NOTIFICATION_PREFIX;

    return $self->_authorize_with_policy( $actor, $parsed, $context || {} );
}

sub parse_channel ($channel) {
    return undef if !defined $channel || ref $channel;
    my ( $type, $resource_id ) = $channel =~
      /\A ([[:lower:]][[:lower:][:digit:]_]*) [:] ([[:alnum:]_.-]+) \z/msxa;
    return undef if !defined $type;

    return {
        type        => $type,
        resource_id => $resource_id,
    };
}

sub _authorize_notifications ( $self, $actor, $parsed ) {
    my $user_id = _user_id($actor);
    return { ok => 1, reason => 'own_notifications' }
      if $user_id eq $parsed->{resource_id};

    return { ok => 0, reason => 'wrong_recipient' };
}

sub _authorize_with_policy ( $self, $actor, $parsed, $context ) {
    return { ok => 0, reason => 'forbidden' } if !$self->permission_engine;

    my $decision = $self->permission_engine->permits(
        $actor,
        'realtime.subscribe',
        {
            type => $parsed->{type},
            id   => $parsed->{resource_id},
        },
        $context
    );

    return _normalize_policy_decision($decision);
}

sub _normalize_policy_decision ($decision) {
    if ( ref $decision eq 'HASH' ) {
        return {
            ok     => $decision->{ok} ? 1 : 0,
            reason => $decision->{reason}
              || ( $decision->{ok} ? 'policy_allowed' : 'forbidden' ),
        };
    }

    return { ok => 1, reason => 'policy_allowed' } if $decision;

    return { ok => 0, reason => 'forbidden' };
}

sub _user_id ($actor) {
    return undef             if !defined $actor;
    return $actor->{user_id} if ref $actor eq 'HASH';

    return $actor;
}

1;

__END__

=head1 NAME

GPForum::Service::Realtime::ChannelAuthorizer - Decides whether an actor may subscribe to a realtime channel.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $authorizer = GPForum::Service::Realtime::ChannelAuthorizer->new(
        permission_engine => GPForum::Service::Realtime::SubscriptionPolicy->new(
            permission_gate  => $permission_gate,
            readability      => $readability,
            schema           => $schema,
            suspension_store => $suspension_store,
        ),
    );
    my $decision = $authorizer->authorize( { user_id => $user_id },
        "thread:$thread_id", {} );
    # { ok => 1, reason => ... } or { ok => 0, reason => 'forbidden' }

    my $parsed = GPForum::Service::Realtime::ChannelAuthorizer::parse_channel(
        "thread:$thread_id");
    # { type => 'thread', resource_id => $thread_id }

=head1 DESCRIPTION

A channel name is C<< <type>:<resource id> >>. Five families exist:
C<thread>, C<notifications>, C<moderation>, C<admin> and C<feed>. There is
no presence family: nothing is published to one, and a cluster-wide
presence would need the shared registry ADR 0067 rules out.

The checks run in order: the name must parse, its type must be one of the
five, and the actor must have a user id. A C<notifications> channel is then
open only to the member it names. Every other family is put to the
C<permission_engine> as the action C<realtime.subscribe> on
C<< { type, id } >>; with no engine set, the answer is C<forbidden>.

=head1 SUBROUTINES/METHODS

=head2 authorize

Takes an actor (a hash reference with C<user_id>, or the user id itself),
a channel name and a context hash reference (undef is treated as an empty
one), which is passed through to the engine. Returns a hash reference with
C<ok> (1 or 0) and C<reason>. Refusals before the engine is asked:
C<malformed_channel>, C<unknown_channel>, C<authentication_required>, and
C<wrong_recipient> for another member's notifications; C<own_notifications>
is the reason for an allowed notifications channel. The engine's answer is
normalized: a hash reference keeps its C<ok> as 1 or 0 and its C<reason>,
which defaults to C<policy_allowed> or C<forbidden>; any other true value
becomes C<< { ok => 1, reason => 'policy_allowed' } >>, and a false one
C<< { ok => 0, reason => 'forbidden' } >>.

=head2 parse_channel

A plain function, not a method; the hub and the tests call it fully
qualified. Takes a channel name. Returns C<< { type, resource_id } >> when
the name is a lower-case type (a letter, then letters, digits or
underscores), a colon and a resource id of letters, digits, C<_>, C<.> or
C<->; returns undef for anything else, including undef and references. It
does not check that the type is a supported family.

=head1 DIAGNOSTICS

None. Every refusal is a returned reason; an exception from the permission
engine propagates.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>; the C<permission_engine> is normally a
L<GPForum::Service::Realtime::SubscriptionPolicy>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A default-constructed authorizer has no C<permission_engine> and refuses
every channel except the actor's own notifications.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
