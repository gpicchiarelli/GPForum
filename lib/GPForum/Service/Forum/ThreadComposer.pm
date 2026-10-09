# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::ThreadComposer;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Service::Forum::BodyRenderer;
use GPForum::Infrastructure::Id;
use GPForum::Service::Forum::Visibility;

our $VERSION = '0.001';

const my $MINIMUM_TITLE_LENGTH => 3;
const my $MAXIMUM_TITLE_LENGTH => 160;
const my $MINIMUM_BODY_LENGTH  => 1;
const my $FIRST_POST_POSITION  => 1;
const my %ALLOWED_VISIBILITY => (
    public  => 1,
    members => 1,
    private => 1,
);

has body_renderer => sub { return GPForum::Service::Forum::BodyRenderer->new; };
has id_service    => sub { return GPForum::Infrastructure::Id->new; };

sub prepare ( $self, $input ) {
    my $floor      = _trim( $input->{visibility_floor} );
    my $visibility = _trim( $input->{visibility} );
    my $values     = {
        category_id     => _trim( $input->{category_id} ),
        author_user_id  => _trim( $input->{author_user_id} ),
        title           => _single_line( $input->{title} ),
        body_source     => _trim( $input->{body_source} ),
        body_hash       => _trim( $input->{body_hash} ),
        idempotency_key => _trim( $input->{idempotency_key} ),

        # ADR 0102: a thread left without a visibility inherits its
        # category's effective visibility (public when the caller gives
        # none), and may not ask for a broader one. Content written in a
        # members-only place stays members-only if that place is later
        # opened.
        visibility_floor => length $floor ? $floor : 'public',
    };
    $values->{visibility} =
      length $visibility ? $visibility : $values->{visibility_floor};

    my $body_error =
      length $values->{body_source} >= $MINIMUM_BODY_LENGTH
      ? undef
      : 'body is required';
    my $errors = _errors(
        $values,
        [qw(category_id author_user_id body_hash)],
        title       => _title_error($values),
        body_source => $body_error,
        visibility  => _visibility_error($values),
    );

    return { ok => 0, errors => $errors, values => $values }
      if keys %{$errors};

    return {
        ok      => 1,
        command => $self->_command($values),
    };
}

sub prepare_title ( $self, $input ) {
    my $values = {
        editor_user_id  => _trim( $input->{editor_user_id} ),
        idempotency_key => _trim( $input->{idempotency_key} ),
        thread_id       => _trim( $input->{thread_id} ),
        title           => _single_line( $input->{title} ),
    };
    my $errors = _errors(
        $values,
        [qw(editor_user_id thread_id)],
        title => _title_error($values),
    );
    if ( keys %{$errors} ) {
        return { ok => 0, errors => $errors, values => $values };
    }

    return {
        ok      => 1,
        command => {
            idempotency_key => $values->{idempotency_key},
            thread          => {
                editor_user_id => $values->{editor_user_id},
                slug           => _slug_from_title( $values->{title} ),
                thread_id      => $values->{thread_id},
                title          => $values->{title},
            },
        },
    };
}

sub prepare_move ( $self, $input ) {
    my $values = {
        category_id     => _trim( $input->{category_id} ),
        editor_user_id  => _trim( $input->{editor_user_id} ),
        idempotency_key => _trim( $input->{idempotency_key} ),
        thread_id       => _trim( $input->{thread_id} ),
    };
    my $errors = _errors( $values, [qw(category_id editor_user_id thread_id)] );
    if ( keys %{$errors} ) {
        return { ok => 0, errors => $errors, values => $values };
    }

    return {
        ok      => 1,
        command => {
            idempotency_key => $values->{idempotency_key},
            thread          => {
                category_id    => $values->{category_id},
                editor_user_id => $values->{editor_user_id},
                thread_id      => $values->{thread_id},
            },
        },
    };
}

# The rows a new thread writes: the thread, its first post with that post's
# body and first revision, and the thread's reply counter.
sub _command ( $self, $values ) {
    my $thread_id   = $self->id_service->uuid;
    my $post_id     = $self->id_service->uuid;
    my $body_id     = $self->id_service->uuid;
    my $revision_id = $self->id_service->uuid;

    # The state the thread and its first post both start in.
    my %new_state = (
        visibility         => $values->{visibility},
        moderation_state   => 'visible',
        version            => 1,
        visibility_version => 1,
        permission_version => 1,
        locked_at          => undef,
        deleted_at         => undef,
        deleted_by         => undef,
    );

    return {
        idempotency_key => $values->{idempotency_key},
        thread          => {
            %new_state,
            thread_id      => $thread_id,
            category_id    => $values->{category_id},
            author_user_id => $values->{author_user_id},
            title          => $values->{title},
            slug           => _slug_from_title( $values->{title} ),
            pinned         => 0,
        },
        post => {
            %new_state,
            post_id             => $post_id,
            thread_id           => $thread_id,
            author_user_id      => $values->{author_user_id},
            current_body_id     => $body_id,
            current_revision_id => $revision_id,
            position            => $FIRST_POST_POSITION,
            hidden_at           => undef,
        },
        body => {
            body_id            => $body_id,
            post_id            => $post_id,
            body_format        => 'markdown',
            body_source        => $values->{body_source},
            body_rendered_safe =>
              $self->body_renderer->render_safe( $values->{body_source} ),
            source_hash => $values->{body_hash},
        },
        revision => {
            revision_id     => $revision_id,
            post_id         => $post_id,
            body_id         => $body_id,
            editor_user_id  => $values->{author_user_id},
            revision_number => 1,
            edit_reason     => undef,
        },
        counter => {
            thread_id           => $thread_id,
            reply_count         => 0,
            visible_reply_count => 0,
            last_post_id        => undef,
            version             => 1,
            reconciled_at       => undef,
        },
    };
}

# The errors of $values: "FIELD is required" for each empty field in
# $required, then each message %checks gives (undef when the value is fine).
sub _errors ( $values, $required, %checks ) {
    my %errors =
      map { length $values->{$_} ? () : ( $_ => "$_ is required" ) }
      @{$required};
    for my $field ( grep { defined $checks{$_} } keys %checks ) {
        $errors{$field} = $checks{$field};
    }

    return \%errors;
}

sub _title_error ($values) {
    my $length = length $values->{title};
    return 'title is required' if !$length;

    return 'title length is invalid'
      if $length < $MINIMUM_TITLE_LENGTH || $length > $MAXIMUM_TITLE_LENGTH;

    return undef;
}

sub _visibility_error ($values) {
    return 'visibility is invalid'
      if !exists $ALLOWED_VISIBILITY{ $values->{visibility} };
    return 'visibility is broader than its category'
      if GPForum::Service::Forum::Visibility->broader( $values->{visibility},
        $values->{visibility_floor} );

    return undef;
}

sub _slug_from_title ($title) {
    my $slug = lc $title;
    $slug =~ s/[^[:alnum:]]+/-/gmsx;
    $slug =~ s/\A [-]+//msx;
    $slug =~ s/[-]+ \z//msx;

    return length $slug ? $slug : 'thread';
}

sub _single_line ($value) {
    my $single_line = _trim($value);
    $single_line =~ s/\s+/ /gmsx;

    return $single_line;
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

GPForum::Service::Forum::ThreadComposer - Validate a new thread, a title edit or a move and build the command to store.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $composer = GPForum::Service::Forum::ThreadComposer->new;
    my $prepared = $composer->prepare(
        {
            author_user_id   => $user_id,
            body_hash        => $body_hash,
            body_source      => $markdown,
            category_id      => $category_id,
            idempotency_key  => $key,
            title            => $title,
            visibility_floor => 'members',
        }
    );
    if ( !$prepared->{ok} ) {
        # $prepared->{errors}{title}, $prepared->{values} to redisplay
    }
    my $command = $prepared->{command};

    my $title_edit = $composer->prepare_title(
        { editor_user_id => $user_id, thread_id => $thread_id, title => $new } );
    my $move = $composer->prepare_move(
        {
            category_id    => $target_category_id,
            editor_user_id => $user_id,
            thread_id      => $thread_id,
        }
    );

=head1 DESCRIPTION

The pure half of creating and changing a thread for
L<GPForum::Service::Forum::PostingWorkflow>: it trims and checks the input
and, when it is valid, builds the records the workflow writes. It reads and
writes nothing in the database.

A new thread is a thread, its first post (position 1), the post's body
(Markdown, with its safe rendering from
L<GPForum::Service::Forum::BodyRenderer>), the first revision and a zeroed
reply counter, with fresh UUIDs for each. A thread left without a
visibility inherits its category's effective visibility, passed in as
C<visibility_floor>, and may not ask for a broader one (ADR 0102), so content
written in a members-only place stays members-only if that place is later
opened. The slug comes from the title: lowercased, every run of characters
that are not letters or digits turned into one hyphen, hyphens trimmed, and
C<thread> when nothing is left.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<body_renderer> and C<id_service> default to
L<GPForum::Service::Forum::BodyRenderer> and L<GPForum::Infrastructure::Id>.

=head2 prepare

Takes a hash reference with C<category_id>, C<author_user_id>, C<title>,
C<body_source>, C<body_hash>, C<idempotency_key>, and optional
C<visibility> and C<visibility_floor> (C<public> when absent). Values are
trimmed; the title is also folded onto one line.

On failure returns C<< { ok => 0, errors => \%errors, values => \%values } >>,
with one message per failing field: C<category_id is required>,
C<author_user_id is required>, C<title is required>,
C<title length is invalid> (fewer than 3 or more than 160 characters),
C<body is required>, C<body_hash is required>, C<visibility is invalid>
(not C<public>, C<members> or C<private>) or
C<visibility is broader than its category>.

On success returns C<< { ok => 1, command => \%command } >>, where the
command holds C<idempotency_key> and the C<thread>, C<post>, C<body>,
C<revision> and C<counter> records.

=head2 prepare_title

Takes a hash reference with C<editor_user_id>, C<thread_id>, C<title> and
C<idempotency_key>. On failure returns C<ok>, C<errors> and C<values> as
L</prepare> does (C<editor_user_id is required>, C<thread_id is required>
and the title messages). On success returns
C<< { ok => 1, command => { idempotency_key, thread => { editor_user_id, slug, thread_id, title } } } >>,
with the slug rebuilt from the new title.

=head2 prepare_move

Takes a hash reference with C<category_id>, C<editor_user_id>,
C<thread_id> and C<idempotency_key>. On failure returns C<ok>, C<errors>
and C<values> (each of the three ids is required). On success returns
C<< { ok => 1, command => { idempotency_key, thread => { category_id, editor_user_id, thread_id } } } >>.
Whether the target category exists or may receive the thread is decided by
the workflow, not here.

=head1 DIAGNOSTICS

Validation failures are returned, never thrown. Errors from the body
renderer or the id service propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Forum::BodyRenderer>, L<GPForum::Service::Forum::Visibility>,
L<GPForum::Infrastructure::Id>.

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
