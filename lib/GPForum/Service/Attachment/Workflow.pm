package GPForum::Service::Attachment::Workflow;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Base -base;

our $VERSION = '0.001';

has delivery    => undef;
has logger      => undef;
has pipeline    => undef;
has post_reader => undef;

sub upload_for_post {
    my ( $self, $input ) = @_;

    return $self->_run_store(
        'post not found',
        sub { return $self->_upload_once($input); },
    );
}

sub download {
    my ( $self, $input ) = @_;

    return $self->_run_store(
        'attachment not found',
        sub { return $self->_download_once($input); },
    );
}

sub _upload_once {
    my ( $self, $input ) = @_;

    my $post = $self->post_reader->find_visible_post( $input->{post_id} );
    if ( !$post ) {
        return;
    }
    if ( !_same_author( $post, $input->{actor_user_id} ) ) {
        return {
            error     => 'post author required',
            forbidden => 1,
        };
    }

    return _linked_upload(
        $self->pipeline->upload_and_link(
            {
                actor_user_id => $input->{actor_user_id},
                target_id     => _column( $post, 'post_id' ),
                target_type   => 'post',
                upload        => $input->{upload},
            }
        ),
        $post,
    );
}

sub _download_once {
    my ( $self, $input ) = @_;

    return $self->delivery->download(
        {
            attachment_id  => $input->{attachment_id},
            viewer_user_id => $input->{viewer_user_id},
        }
    );
}

sub _linked_upload {
    my ( $uploaded, $post ) = @_;

    if ( !$uploaded ) {
        return;
    }
    if ( !$uploaded->{ok} ) {
        return {
            errors  => $uploaded->{errors} || {},
            invalid => 1,
        };
    }

    return { %{$uploaded}, post => $post, };
}

sub _same_author {
    my ( $post, $user_id ) = @_;

    return ( _column( $post, 'author_user_id' ) || q{} ) eq ( $user_id || q{} );
}

sub _run_store {
    my ( $self, $not_found, $code ) = @_;

    my $stored = $self->_eval_store($code);
    if ( $stored->{failed} ) {
        return _result(
            error  => 'attachment store failed',
            status => 'failed',
        );
    }

    return _stored_result( $not_found, $stored->{value} );
}

sub _eval_store {
    my ( $self, $code ) = @_;

    my $value = eval { return $code->(); };
    if ($EVAL_ERROR) {
        $self->_log_error("attachment write failed: $EVAL_ERROR");
        return { failed => 1 };
    }

    return { value => $value };
}

sub _stored_result {
    my ( $not_found, $value ) = @_;

    if ( !$value ) {
        return _result(
            error  => $not_found,
            status => 'not_found',
        );
    }

    return _classified_result($value);
}

sub _classified_result {
    my ($value) = @_;

    my $denied = _denied_result($value);
    if ($denied) {
        return $denied;
    }

    return _result(
        status => 'ok',
        stored => $value,
    );
}

sub _denied_result {
    my ($value) = @_;

    my $tagged = _tagged_denial($value);
    if ($tagged) {
        return $tagged;
    }

    return _store_denial($value);
}

sub _tagged_denial {
    my ($value) = @_;

    if ( $value->{forbidden} ) {
        return _result(
            error  => $value->{error},
            status => 'forbidden',
        );
    }
    if ( $value->{invalid} ) {
        return _result(
            errors => $value->{errors},
            status => 'invalid',
        );
    }

    return;
}

sub _store_denial {
    my ($value) = @_;

    if ( _is_missing($value) ) {
        return _result(
            error  => $value->{error} || 'attachment not found',
            status => 'not_found',
        );
    }
    if ( _is_denied($value) ) {
        return _result(
            error  => $value->{error} || 'attachment is not available',
            status => 'forbidden',
        );
    }

    return;
}

sub _is_missing {
    my ($value) = @_;

    if ( !_has_ok($value) ) {
        return 0;
    }

    return $value->{ok} ? 0 : ( $value->{error} || q{} ) eq 'not_found';
}

sub _is_denied {
    my ($value) = @_;

    if ( !_has_ok($value) ) {
        return 0;
    }

    return $value->{ok} ? 0 : 1;
}

sub _has_ok {
    my ($value) = @_;

    if ( ref $value ne 'HASH' ) {
        return 0;
    }

    return exists $value->{ok} ? 1 : 0;
}

sub _column {
    my ( $row, $name ) = @_;

    if ( !$row ) {
        return;
    }
    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }

    return _object_column( $row, $name );
}

sub _object_column {
    my ( $row, $name ) = @_;

    if ( $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return;
}

sub _result {
    my (%input) = @_;

    return {
        error  => $input{error},
        errors => $input{errors},
        ok     => ( $input{status} || q{} ) eq 'ok' ? 1 : 0,
        status => $input{status} || 'failed',
        stored => $input{stored},
    };
}

sub _log_error {
    my ( $self, $message ) = @_;

    if ( !$self->logger || !$self->logger->can('error') ) {
        return;
    }

    $self->logger->error($message);

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Attachment::Workflow - Attachment upload and download writes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = $workflow->upload_for_post(
        {
            actor_user_id => $user_id,
            post_id       => $post_id,
            upload        => $upload,
        }
    );

=head1 DESCRIPTION

Application boundary for post attachment uploads and attachment downloads.
Looks up a visible post, enforces author ownership, and delegates binary
storage to the existing upload pipeline and delivery service. Returns a
normalized result hash. Stores keep transaction, event, audit, and object
storage ownership.

=head1 SUBROUTINES/METHODS

=head2 upload_for_post

Uploads and links an attachment to a visible post owned by the actor.

=head2 download

Delivers attachment bytes for an authorized viewer.

=head1 DIAGNOSTICS

Returns C<invalid>, C<not_found>, C<forbidden>, or C<failed> statuses instead
of throwing for expected outcomes. Unexpected store exceptions are logged and
mapped to C<failed>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses post reader, upload pipeline, and delivery services supplied by the
composition root.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Rate limits and CSRF checks remain in the HTTP controller.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
