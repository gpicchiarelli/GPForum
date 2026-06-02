package GPForum::Service::Forum::PostComposer;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Id;

our $VERSION = '0.001';

const my $MINIMUM_BODY_LENGTH => 1;
const my $FIRST_REVISION      => 1;
const my $COUNTER_SHARD_ID    => 0;
const my %ALLOWED_VISIBILITY => (
    public  => 1,
    members => 1,
    private => 1,
);

has id_service => sub { return GPForum::Service::Id->new; };

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
        post_id     => $self->id_service->uuid,
        body_id     => $self->id_service->uuid,
        revision_id => $self->id_service->uuid,
    };

    return {
        idempotency_key => $values->{idempotency_key},
        post            => _post_record( $values, $ids ),
        body            => _body_record( $values, $ids ),
        revision        => _revision_record( $values, $ids ),
        counter_shard   => _counter_shard_record($values),
    };
}

sub _post_record {
    my ( $values, $ids ) = @_;

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

sub _body_record {
    my ( $values, $ids ) = @_;

    return {
        body_id            => $ids->{body_id},
        post_id            => $ids->{post_id},
        body_format        => 'markdown',
        body_source        => $values->{body_source},
        body_rendered_safe => _render_safe_text( $values->{body_source} ),
        source_hash        => $values->{body_hash},
    };
}

sub _revision_record {
    my ( $values, $ids ) = @_;

    return {
        revision_id     => $ids->{revision_id},
        post_id         => $ids->{post_id},
        body_id         => $ids->{body_id},
        editor_user_id  => $values->{author_user_id},
        revision_number => $FIRST_REVISION,
        edit_reason     => undef,
    };
}

sub _counter_shard_record {
    my ($values) = @_;

    return {
        thread_id         => $values->{thread_id},
        shard_id          => $COUNTER_SHARD_ID,
        reply_count_delta => 1,
    };
}

sub _normalized_values {
    my ($input) = @_;

    return {
        thread_id         => _trim( $input->{thread_id} ),
        author_user_id    => _trim( $input->{author_user_id} ),
        position          => _integer_value( $input->{position} ),
        allocate_position => $input->{allocate_position} ? 1 : 0,
        body_source       => _trim( $input->{body_source} ),
        body_hash         => _trim( $input->{body_hash} ),
        idempotency_key   => _trim( $input->{idempotency_key} ),
        visibility        => _visibility($input),
    };
}

sub _validation_errors {
    my ($values) = @_;

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

sub _position_error {
    my ($values) = @_;

    return if $values->{allocate_position};

    return $values->{position} > 0 ? undef : 'position is invalid';
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

sub _visibility {
    my ($input) = @_;

    my $visibility = _trim( $input->{visibility} );

    return length $visibility ? $visibility : 'public';
}

sub _integer_value {
    my ($value) = @_;

    return defined $value && $value =~ /\A [[:digit:]]+ \z/msx ? int $value : 0;
}

sub _render_safe_text {
    my ($body) = @_;

    my $safe = $body;
    $safe =~ s/[&]/&amp;/gmsx;
    $safe =~ s/[<]/&lt;/gmsx;
    $safe =~ s/[>]/&gt;/gmsx;

    return $safe;
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
