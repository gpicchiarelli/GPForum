# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::PostComposer;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Service::Forum::BodyRenderer;
use GPForum::Infrastructure::Id;
use GPForum::Service::Forum::Visibility;

our $VERSION = '0.001';

const my $MINIMUM_BODY_LENGTH => 1;
const my $FIRST_REVISION      => 1;
const my %ALLOWED_VISIBILITY => (
    public  => 1,
    members => 1,
    private => 1,
);

has body_renderer => sub { return GPForum::Service::Forum::BodyRenderer->new; };
has id_service    => sub { return GPForum::Infrastructure::Id->new; };

sub prepare ( $self, $input ) {
    my $values = _normalized_values($input);
    my $errors = _validation_errors($values);

    return { ok => 0, errors => $errors, values => $values }
      if keys %{$errors};

    return {
        ok      => 1,
        command => $self->_command($values),
    };
}

sub prepare_revision ( $self, $input ) {
    my $values = _normalized_revision_values($input);
    my $errors = _revision_validation_errors($values);

    return { ok => 0, errors => $errors, values => $values }
      if keys %{$errors};

    return {
        ok      => 1,
        command => $self->_revision_command($values),
    };
}

sub _command ( $self, $values ) {
    my $ids = {
        post_id     => $self->id_service->uuid,
        body_id     => $self->id_service->uuid,
        revision_id => $self->id_service->uuid,
    };

    return {
        idempotency_key => $values->{idempotency_key},
        post            => _post_record( $values, $ids ),
        body            => $self->_body_record( $values, $ids ),
        revision        => _revision_record( $values, $ids ),
    };
}

sub _revision_command ( $self, $values ) {
    my $ids = {
        body_id     => $self->id_service->uuid,
        revision_id => $self->id_service->uuid,
    };

    return {
        body            => $self->_body_record( $values, $ids ),
        idempotency_key => $values->{idempotency_key},
        post            => {
            editor_user_id => $values->{editor_user_id},
            post_id        => $values->{post_id},
            thread_id      => $values->{thread_id},
        },
        revision => _revision_record( $values, $ids ),
    };
}

sub _post_record ( $values, $ids ) {
    return {
        post_id             => $ids->{post_id},
        thread_id           => $values->{thread_id},
        author_user_id      => $values->{author_user_id},
        current_body_id     => $ids->{body_id},
        current_revision_id => $ids->{revision_id},
        position            => $values->{position},
        visibility          => $values->{visibility},
        moderation_state    => 'visible',
        version             => 1,
        visibility_version  => 1,
        permission_version  => 1,
        hidden_at           => undef,
        locked_at           => undef,
        deleted_at          => undef,
        deleted_by          => undef,
    };
}

sub _body_record ( $self, $values, $ids ) {
    return {
        body_id            => $ids->{body_id},
        post_id            => $ids->{post_id} || $values->{post_id},
        body_format        => 'markdown',
        body_source        => $values->{body_source},
        body_rendered_safe =>
          $self->body_renderer->render_safe( $values->{body_source} ),
        source_hash => $values->{body_hash},
    };
}

sub _revision_record ( $values, $ids ) {
    return {
        revision_id    => $ids->{revision_id},
        post_id        => $ids->{post_id} || $values->{post_id},
        body_id        => $ids->{body_id},
        editor_user_id => $values->{editor_user_id}
          || $values->{author_user_id},
        revision_number => _revision_number($values),
        edit_reason     => $values->{edit_reason},
    };
}

sub _normalized_values ($input) {
    return {
        thread_id         => _trim( $input->{thread_id} ),
        author_user_id    => _trim( $input->{author_user_id} ),
        position          => _integer_value( $input->{position} ),
        allocate_position => $input->{allocate_position} ? 1 : 0,
        body_source       => _trim( $input->{body_source} ),
        body_hash         => _trim( $input->{body_hash} ),
        idempotency_key   => _trim( $input->{idempotency_key} ),
        visibility        => _visibility($input),
        visibility_floor  => _visibility_floor($input),
    };
}

sub _normalized_revision_values ($input) {
    return {
        allocate_revision => 1,
        body_hash         => _trim( $input->{body_hash} ),
        body_source       => _trim( $input->{body_source} ),
        edit_reason       => _optional_text( $input->{edit_reason} ),
        editor_user_id    => _trim( $input->{editor_user_id} ),
        idempotency_key   => _trim( $input->{idempotency_key} ),
        post_id           => _trim( $input->{post_id} ),
        revision_number   => 0,
        thread_id         => _trim( $input->{thread_id} ),
    };
}

sub _optional_text ($value) {
    my $text = _trim($value);

    return length $text ? $text : undef;
}

sub _revision_number ($values) {
    return 0 if $values->{allocate_revision};

    return $values->{revision_number} || $FIRST_REVISION;
}

sub _validation_errors ($values) {
    my %errors;

    _set_error( \%errors, 'thread_id',
        _required_error( $values, 'thread_id' ) );
    _set_error( \%errors, 'author_user_id',
        _required_error( $values, 'author_user_id' ) );
    _set_error( \%errors, 'position',    _position_error($values) );
    _set_error( \%errors, 'body_source', _body_error($values) );
    _set_error( \%errors, 'body_hash',
        _required_error( $values, 'body_hash' ) );
    _set_error( \%errors, 'visibility', _visibility_error($values) );

    return \%errors;
}

sub _revision_validation_errors ($values) {
    my %errors;

    _set_error( \%errors, 'post_id', _required_error( $values, 'post_id' ) );
    _set_error( \%errors, 'editor_user_id',
        _required_error( $values, 'editor_user_id' ) );
    _set_error( \%errors, 'body_source', _body_error($values) );
    _set_error( \%errors, 'body_hash',
        _required_error( $values, 'body_hash' ) );

    return \%errors;
}

sub _set_error ( $errors, $field, $message ) {
    if ( defined $message && length $message ) {
        $errors->{$field} = $message;
    }

    return;
}

sub _required_error ( $values, $field ) {
    return length $values->{$field} ? undef : "$field is required";
}

sub _position_error ($values) {
    return undef if $values->{allocate_position};

    return $values->{position} > 0 ? undef : 'position is invalid';
}

sub _body_error ($values) {
    return length $values->{body_source} >= $MINIMUM_BODY_LENGTH
      ? undef
      : 'body is required';
}

sub _visibility_error ($values) {
    return 'visibility is invalid'
      if !exists $ALLOWED_VISIBILITY{ $values->{visibility} };
    return 'visibility is broader than its thread'
      if GPForum::Service::Forum::Visibility->broader( $values->{visibility},
        $values->{visibility_floor} );

    return undef;
}

# ADR 0102: a reply left without a visibility inherits its thread's effective
# visibility, and may not ask for a broader one. Content written in a
# members-only place stays members-only if that place is later opened.
sub _visibility ($input) {
    my $visibility = _trim( $input->{visibility} );

    return length $visibility ? $visibility : _visibility_floor($input);
}

# The thread's effective visibility, given by the caller; public when none is.
sub _visibility_floor ($input) {
    my $floor = _trim( $input->{visibility_floor} );

    return length $floor ? $floor : 'public';
}

sub _integer_value ($value) {
    return defined $value && $value =~ /\A [[:digit:]]+ \z/msx ? int $value : 0;
}

sub _trim ($value) {
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

GPForum::Service::Forum::PostComposer - Validate a new reply or an edit and build the rows the post store writes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $composer = GPForum::Service::Forum::PostComposer->new;

    my $prepared = $composer->prepare(
        {
            allocate_position => 1,
            author_user_id    => $user_id,
            body_hash         => $body_hash,
            body_source       => $markdown,
            idempotency_key   => $command_id,
            thread_id         => $thread_id,
            visibility_floor  => 'members',
        }
    );
    return $prepared->{errors} if !$prepared->{ok};
    my $command = $prepared->{command};

    my $edit = $composer->prepare_revision(
        {
            body_hash       => $new_hash,
            body_source     => $new_markdown,
            edit_reason     => 'typo',
            editor_user_id  => $user_id,
            idempotency_key => $command_id,
            post_id         => $post_id,
            thread_id       => $thread_id,
        }
    );

=head1 DESCRIPTION

The pure part of writing a reply or an edit: the input is trimmed and
checked, the body is rendered to safe HTML through
L<GPForum::Service::Forum::BodyRenderer>, and the result is a command of
plain hashes that L<GPForum::Service::Forum::PostStore> writes in one
transaction. Nothing is read or written here.

A reply left without a visibility takes its thread's effective visibility
(C<visibility_floor>, public when not given), and may not ask for a broader
one (ADR 0102): content written in a members-only place stays members-only
if that place is later opened.

=head1 SUBROUTINES/METHODS

=head2 prepare

Takes a hash reference with C<thread_id>, C<author_user_id>,
C<body_source>, C<body_hash>, C<idempotency_key>, optional C<visibility>
and C<visibility_floor>, and either a positive C<position> or a true
C<allocate_position>. Returns C<< { ok => 0, errors, values } >> with the
normalized values, or C<< { ok => 1, command } >>, the command holding:
C<idempotency_key>; C<post>, with new post, body and revision ids, the
thread, author, position (0 when none was given, which the post store
replaces with the thread's next position) and visibility, moderation state
C<visible>, versions at 1 and empty hidden, locked and deleted columns;
C<body>, the Markdown source, its rendered HTML and the source hash;
C<revision>, number 1 by the author.

=head2 prepare_revision

Takes a hash reference with C<post_id>, C<thread_id>, C<editor_user_id>,
C<body_source>, C<body_hash>, C<idempotency_key> and an optional
C<edit_reason>. Returns C<< { ok => 0, errors, values } >>, or
C<< { ok => 1, command } >> with C<idempotency_key>, C<post> (the post id,
thread id and editor), a new C<body> and a C<revision> by the editor with
number 0, which the post store replaces with the post's next revision
number.

=head1 DIAGNOSTICS

Nothing is thrown. The errors returned are C<FIELD is required> for
C<thread_id>, C<author_user_id>, C<post_id>, C<editor_user_id> and
C<body_hash>; C<position is invalid>; C<body is required>;
C<visibility is invalid> for anything but C<public>, C<members> and
C<private>; and C<visibility is broader than its thread>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Forum::BodyRenderer>, L<GPForum::Infrastructure::Id>,
L<GPForum::Service::Forum::Visibility>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
