# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::ThreadComposer;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

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
    my $values = _normalized_values($input);
    my $errors = _validation_errors($values);

    return { ok => 0, errors => $errors, values => $values }
      if keys %{$errors};

    return {
        ok      => 1,
        command => $self->_command($values),
    };
}

sub prepare_title ( $self, $input ) {
    my $values = _title_edit_values($input);
    my $errors = _title_edit_errors($values);
    if ( keys %{$errors} ) {
        return { ok => 0, errors => $errors, values => $values };
    }

    return {
        ok      => 1,
        command => _title_command($values),
    };
}

sub prepare_move ( $self, $input ) {
    my $values = _move_values($input);
    my $errors = _move_errors($values);
    if ( keys %{$errors} ) {
        return { ok => 0, errors => $errors, values => $values };
    }

    return {
        ok      => 1,
        command => _move_command($values),
    };
}

sub _command ( $self, $values ) {
    my $ids = {
        thread_id   => $self->id_service->uuid,
        post_id     => $self->id_service->uuid,
        body_id     => $self->id_service->uuid,
        revision_id => $self->id_service->uuid,
    };

    return {
        idempotency_key => $values->{idempotency_key},
        thread          => _thread_record( $values, $ids ),
        post            => _post_record( $values, $ids ),
        body            => $self->_body_record( $values, $ids ),
        revision        => _revision_record( $values, $ids ),
        counter         => _counter_record( $ids->{thread_id} ),
    };
}

sub _thread_record ( $values, $ids ) {
    return {
        thread_id          => $ids->{thread_id},
        category_id        => $values->{category_id},
        author_user_id     => $values->{author_user_id},
        title              => $values->{title},
        slug               => _slug_from_title( $values->{title} ),
        pinned             => 0,
        visibility         => $values->{visibility},
        moderation_state   => 'visible',
        locked_at          => undef,
        version            => 1,
        visibility_version => 1,
        permission_version => 1,
        deleted_at         => undef,
        deleted_by         => undef,
    };
}

sub _post_record ( $values, $ids ) {
    return {
        post_id             => $ids->{post_id},
        thread_id           => $ids->{thread_id},
        author_user_id      => $values->{author_user_id},
        current_body_id     => $ids->{body_id},
        current_revision_id => $ids->{revision_id},
        position            => $FIRST_POST_POSITION,
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
        post_id            => $ids->{post_id},
        body_format        => 'markdown',
        body_source        => $values->{body_source},
        body_rendered_safe =>
          $self->body_renderer->render_safe( $values->{body_source} ),
        source_hash => $values->{body_hash},
    };
}

sub _revision_record ( $values, $ids ) {
    return {
        revision_id     => $ids->{revision_id},
        post_id         => $ids->{post_id},
        body_id         => $ids->{body_id},
        editor_user_id  => $values->{author_user_id},
        revision_number => 1,
        edit_reason     => undef,
    };
}

sub _counter_record ($thread_id) {
    return {
        thread_id           => $thread_id,
        reply_count         => 0,
        visible_reply_count => 0,
        last_post_id        => undef,
        version             => 1,
        reconciled_at       => undef,
    };
}

sub _normalized_values ($input) {
    return {
        category_id      => _trim( $input->{category_id} ),
        author_user_id   => _trim( $input->{author_user_id} ),
        title            => _single_line( $input->{title} ),
        body_source      => _trim( $input->{body_source} ),
        body_hash        => _trim( $input->{body_hash} ),
        idempotency_key  => _trim( $input->{idempotency_key} ),
        visibility       => _visibility($input),
        visibility_floor => _visibility_floor($input),
    };
}

sub _validation_errors ($values) {
    my %errors;

    _set_error( \%errors, 'category_id',
        _required_error( $values, 'category_id' ) );
    _set_error( \%errors, 'author_user_id',
        _required_error( $values, 'author_user_id' ) );
    _set_error( \%errors, 'title',       _title_error($values) );
    _set_error( \%errors, 'body_source', _body_error($values) );
    _set_error( \%errors, 'body_hash',
        _required_error( $values, 'body_hash' ) );
    _set_error( \%errors, 'visibility', _visibility_error($values) );

    return \%errors;
}

sub _title_edit_values ($input) {
    return {
        editor_user_id  => _trim( $input->{editor_user_id} ),
        idempotency_key => _trim( $input->{idempotency_key} ),
        thread_id       => _trim( $input->{thread_id} ),
        title           => _single_line( $input->{title} ),
    };
}

sub _title_edit_errors ($values) {
    my %errors;
    _set_error( \%errors, 'editor_user_id',
        _required_error( $values, 'editor_user_id' ) );
    _set_error( \%errors, 'thread_id',
        _required_error( $values, 'thread_id' ) );
    _set_error( \%errors, 'title', _title_error($values) );

    return \%errors;
}

sub _title_command ($values) {
    return {
        idempotency_key => $values->{idempotency_key},
        thread          => {
            editor_user_id => $values->{editor_user_id},
            slug           => _slug_from_title( $values->{title} ),
            thread_id      => $values->{thread_id},
            title          => $values->{title},
        },
    };
}

sub _move_values ($input) {
    return {
        category_id     => _trim( $input->{category_id} ),
        editor_user_id  => _trim( $input->{editor_user_id} ),
        idempotency_key => _trim( $input->{idempotency_key} ),
        thread_id       => _trim( $input->{thread_id} ),
    };
}

sub _move_errors ($values) {
    my %errors;
    _set_error( \%errors, 'category_id',
        _required_error( $values, 'category_id' ) );
    _set_error( \%errors, 'editor_user_id',
        _required_error( $values, 'editor_user_id' ) );
    _set_error( \%errors, 'thread_id',
        _required_error( $values, 'thread_id' ) );

    return \%errors;
}

sub _move_command ($values) {
    return {
        idempotency_key => $values->{idempotency_key},
        thread          => {
            category_id    => $values->{category_id},
            editor_user_id => $values->{editor_user_id},
            thread_id      => $values->{thread_id},
        },
    };
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

sub _title_error ($values) {
    return 'title is required'
      if !length $values->{title};

    return 'title length is invalid'
      if !_length_between( $values->{title}, $MINIMUM_TITLE_LENGTH,
        $MAXIMUM_TITLE_LENGTH );

    my $undefined;
    return $undefined;
}

sub _body_error ($values) {
    return length $values->{body_source} >= $MINIMUM_BODY_LENGTH
      ? undef
      : 'body is required';
}

sub _visibility_error ($values) {
    return 'visibility is invalid'
      if !exists $ALLOWED_VISIBILITY{ $values->{visibility} };
    return 'visibility is broader than its category'
      if GPForum::Service::Forum::Visibility->broader( $values->{visibility},
        $values->{visibility_floor} );

    my $undefined;
    return $undefined;
}

sub _length_between ( $value, $minimum, $maximum ) {
    return length $value >= $minimum && length $value <= $maximum ? 1 : 0;
}

# ADR 0102: a thread left without a visibility inherits its category's effective
# visibility, and may not ask for a broader one. Content written in a
# members-only place stays members-only if that place is later opened.
sub _visibility ($input) {
    my $visibility = _trim( $input->{visibility} );

    return length $visibility ? $visibility : _visibility_floor($input);
}

# The category's effective visibility, given by the caller; public when none is.
sub _visibility_floor ($input) {
    my $floor = _trim( $input->{visibility_floor} );

    return length $floor ? $floor : 'public';
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
