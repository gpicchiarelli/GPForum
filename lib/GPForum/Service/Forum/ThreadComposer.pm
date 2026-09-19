package GPForum::Service::Forum::ThreadComposer;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Forum::BodyRenderer;
use GPForum::Service::Id;

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
has id_service    => sub { return GPForum::Service::Id->new; };

sub prepare {
    my ( $self, $input ) = @_;

    my $values = _normalized_values($input);
    my $errors = _validation_errors($values);

    return { ok => 0, errors => $errors, values => $values }
      if keys %{$errors};

    return {
        ok      => 1,
        command => $self->_command($values),
    };
}

sub _command {
    my ( $self, $values ) = @_;

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

sub _thread_record {
    my ( $values, $ids ) = @_;

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

sub _post_record {
    my ( $values, $ids ) = @_;

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

sub _body_record {
    my ( $self, $values, $ids ) = @_;

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

sub _revision_record {
    my ( $values, $ids ) = @_;

    return {
        revision_id     => $ids->{revision_id},
        post_id         => $ids->{post_id},
        body_id         => $ids->{body_id},
        editor_user_id  => $values->{author_user_id},
        revision_number => 1,
        edit_reason     => undef,
    };
}

sub _counter_record {
    my ($thread_id) = @_;

    return {
        thread_id           => $thread_id,
        reply_count         => 0,
        visible_reply_count => 0,
        last_post_id        => undef,
        version             => 1,
        reconciled_at       => undef,
    };
}

sub _normalized_values {
    my ($input) = @_;

    return {
        category_id     => _trim( $input->{category_id} ),
        author_user_id  => _trim( $input->{author_user_id} ),
        title           => _single_line( $input->{title} ),
        body_source     => _trim( $input->{body_source} ),
        body_hash       => _trim( $input->{body_hash} ),
        idempotency_key => _trim( $input->{idempotency_key} ),
        visibility      => _visibility($input),
    };
}

sub _validation_errors {
    my ($values) = @_;

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

sub _set_error {
    my ( $errors, $field, $message ) = @_;

    if ( defined $message && length $message ) {
        $errors->{$field} = $message;
    }

    return;
}

sub _required_error {
    my ( $values, $field ) = @_;

    return length $values->{$field} ? undef : "$field is required";
}

sub _title_error {
    my ($values) = @_;

    return 'title is required'
      if !length $values->{title};

    return 'title length is invalid'
      if !_length_between( $values->{title}, $MINIMUM_TITLE_LENGTH,
        $MAXIMUM_TITLE_LENGTH );

    return;
}

sub _body_error {
    my ($values) = @_;

    return length $values->{body_source} >= $MINIMUM_BODY_LENGTH
      ? undef
      : 'body is required';
}

sub _visibility_error {
    my ($values) = @_;

    return exists $ALLOWED_VISIBILITY{ $values->{visibility} }
      ? undef
      : 'visibility is invalid';
}

sub _length_between {
    my ( $value, $minimum, $maximum ) = @_;

    return length $value >= $minimum && length $value <= $maximum ? 1 : 0;
}

sub _visibility {
    my ($input) = @_;

    my $visibility = _trim( $input->{visibility} );

    return length $visibility ? $visibility : 'public';
}

sub _slug_from_title {
    my ($title) = @_;

    my $slug = lc $title;
    $slug =~ s/[^[:alnum:]]+/-/gmsx;
    $slug =~ s/\A [-]+//msx;
    $slug =~ s/[-]+ \z//msx;

    return length $slug ? $slug : 'thread';
}

sub _single_line {
    my ($value) = @_;

    my $single_line = _trim($value);
    $single_line =~ s/\s+/ /gmsx;

    return $single_line;
}

sub _trim {
    my ($value) = @_;

    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

1;
