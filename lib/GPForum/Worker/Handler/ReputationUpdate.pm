package GPForum::Worker::Handler::ReputationUpdate;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $THREAD_CREATED  => 'thread.created';
const my $POST_CREATED    => 'post.created';
const my $POST_HIDDEN     => 'post.hidden';
const my $POST_RESTORED   => 'post.restored';
const my $THREAD_HIDDEN   => 'thread.hidden';
const my $THREAD_RESTORED => 'thread.restored';
const my $USER_SUSPENDED  => 'user.suspended';
const my $USER_REVOKED    => 'user.suspension_revoked';

const my $THREAD_CREATED_DELTA  => 2;
const my $POST_CREATED_DELTA    => 1;
const my $POST_HIDDEN_DELTA     => -10;
const my $POST_RESTORED_DELTA   => 10;
const my $THREAD_HIDDEN_DELTA   => -10;
const my $THREAD_RESTORED_DELTA => 10;
const my $SUSPENDED_DELTA       => -50;
const my $REVOKED_DELTA         => 50;

const my %POLICY => (
    $THREAD_CREATED =>
      { delta => $THREAD_CREATED_DELTA, reason => 'thread_created' },
    $POST_CREATED => { delta => $POST_CREATED_DELTA, reason => 'post_created' },
    $POST_HIDDEN  => { delta => $POST_HIDDEN_DELTA,  reason => 'post_hidden' },
    $POST_RESTORED =>
      { delta => $POST_RESTORED_DELTA, reason => 'post_restored' },
    $THREAD_HIDDEN =>
      { delta => $THREAD_HIDDEN_DELTA, reason => 'thread_hidden' },
    $THREAD_RESTORED =>
      { delta => $THREAD_RESTORED_DELTA, reason => 'thread_restored' },
    $USER_SUSPENDED =>
      { delta => $SUSPENDED_DELTA, reason => 'user_suspended' },
    $USER_REVOKED =>
      { delta => $REVOKED_DELTA, reason => 'user_suspension_revoked' },
);

has ledger => undef;
has schema => undef;
has sink   => undef;

sub supports {
    my ( undef, $event ) = @_;

    return _policy( $event->{event_type} ) ? 1 : 0;
}

sub handle {
    my ( $self, $event ) = @_;

    my $policy = _policy( $event->{event_type} );
    my $task   = _task( $event, $policy );
    $self->_capture($task);
    $task->{recorded} = $self->_record( $event, $policy );

    return $task;
}

sub _record {
    my ( $self, $event, $policy ) = @_;

    return if !$self->ledger;

    my $user_id = $self->_subject_user_id($event);
    return { ok => 0, skipped => 1, reason => 'missing_subject' }
      if !_has_text($user_id);

    return $self->ledger->record_event(
        {
            actor_id    => $event->{actor_id},
            delta       => $policy->{delta},
            reason      => $policy->{reason},
            source_id   => _source_id($event),
            source_type => $event->{aggregate_type},
            user_id     => $user_id,
        }
    );
}

sub _subject_user_id {
    my ( $self, $event ) = @_;

    return $event->{aggregate_id} if _user_subject($event);

    my $author = _event_value( $event, 'author_user_id' );
    return $author            if _has_text($author);
    return $event->{actor_id} if _creation_event($event);

    return $self->_schema_author($event);
}

sub _schema_author {
    my ( $self, $event ) = @_;

    my $name = _author_resultset($event);
    return if !$self->schema || !$name;

    my $row = $self->schema->resultset($name)->find( $event->{aggregate_id} );
    return if !$row;

    return $row->get_column('author_user_id');
}

sub _capture {
    my ( $self, $task ) = @_;

    return if !$self->sink;

    $self->sink->capture($task);

    return;
}

sub _task {
    my ( $event, $policy ) = @_;

    return {
        action         => 'reputation.record',
        aggregate_id   => $event->{aggregate_id},
        aggregate_type => $event->{aggregate_type},
        delta          => $policy->{delta},
        event_id       => $event->{event_id},
        reason         => $policy->{reason},
    };
}

sub _policy {
    my ($event_type) = @_;

    return if !defined $event_type;
    return if !exists $POLICY{$event_type};

    return $POLICY{$event_type};
}

sub _user_subject {
    my ($event) = @_;

    my $event_type = $event->{event_type} || q{};

    return $event_type eq $USER_SUSPENDED || $event_type eq $USER_REVOKED
      ? 1
      : 0;
}

sub _creation_event {
    my ($event) = @_;

    my $event_type = $event->{event_type} || q{};

    return $event_type eq $THREAD_CREATED || $event_type eq $POST_CREATED
      ? 1
      : 0;
}

sub _author_resultset {
    my ($event) = @_;

    my $type = $event->{aggregate_type} || q{};
    return 'Post'   if $type eq 'post';
    return 'Thread' if $type eq 'thread';

    return;
}

sub _event_value {
    my ( $event, $name ) = @_;

    return $event->{$name} if defined $event->{$name};

    my $payload = $event->{domain_payload} || {};

    return $payload->{$name};
}

sub _source_id {
    my ($event) = @_;

    if ( _has_text( $event->{aggregate_id} ) ) {
        return $event->{aggregate_id};
    }
    if ( _has_text( $event->{event_id} ) ) {
        return $event->{event_id};
    }

    return;
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Worker::Handler::ReputationUpdate - Apply trust updates from events.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $handler = GPForum::Worker::Handler::ReputationUpdate->new(
        ledger => $ledger,
        schema => $schema,
    );
    $handler->handle($event) if $handler->supports($event);

=head1 DESCRIPTION

Outbox handler that calls L<GPForum::Service::Community::ReputationLedger> for
created posts and threads, hide/restore, and suspension events. Subject users
come from the event payload or, for moderation actions, the post/thread author.

=head1 SUBROUTINES/METHODS

=head2 supports

True when the event type has an explicit reputation policy.

=head2 handle

Records one ledger event for the subject user, or skips when no subject can be
resolved. C<source_id> is the aggregate id, or the event id when the aggregate
id is absent. The ledger skips a record that still has no source.

=head1 DIAGNOSTICS

Returns C<skipped> with C<missing_subject> when the author cannot be resolved.
The ledger returns C<skipped> with C<missing_source> when source type or id is
absent, without applying a delta. Ledger errors propagate to the outbox
dispatcher.

=head1 CONFIGURATION AND ENVIRONMENT

Wired from L<GPForum::Bootstrap::Workers> onto the existing outbox transport.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not invent like or helpful-vote events. Lock/unlock and report resolution
do not change trust. Hide/restore need a schema lookup when the payload omits
C<author_user_id>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
