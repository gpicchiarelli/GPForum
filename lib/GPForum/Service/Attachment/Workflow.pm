# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::Workflow;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

has command_idempotency => undef;
has delivery            => undef;
has logger              => undef;
has pipeline            => undef;
has post_reader         => undef;
has store               => undef;

sub upload_for_post ( $self, $input ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_upload($input);
}

sub _commanded_upload ( $self, $input ) {
    return $self->_commanded_write(
        {
            actor_id     => $input->{actor_user_id},
            command_id   => $input->{command_id},
            command_type => 'attachment.upload',
            request      => {
                actor_user_id => $input->{actor_user_id},
                post_id       => $input->{post_id},
            },
            run => sub { return $self->_upload_store_write($input); },
        }
    );
}

sub _upload_store_write ( $self, $input ) {
    return _public_write_result(
        $self->_run_store(
            'post not found',
            sub { return $self->_upload_once($input); },
        )
    );
}

sub download ( $self, $input ) {
    return $self->_run_store(
        'attachment not found',
        sub { return $self->_download_once($input); },
    );
}

sub _upload_once ( $self, $input ) {
    my $post = $self->post_reader->find_visible_post( $input->{post_id},
        $input->{viewer} );
    if ( !$post ) {
        my $undefined;
        return $undefined;
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

sub delete_for_post ( $self, $input ) {
    my $invalid = $self->_missing_command_id($input);
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_delete($input);
}

sub _commanded_delete ( $self, $input ) {
    return $self->_commanded_write(
        {
            actor_id     => $input->{actor_user_id},
            command_id   => $input->{command_id},
            command_type => 'attachment.delete',
            request      => {
                actor_user_id => $input->{actor_user_id},
                attachment_id => $input->{attachment_id},
                post_id       => $input->{post_id},
            },
            run => sub { return $self->_delete_store_write($input); },
        }
    );
}

sub _delete_store_write ( $self, $input ) {
    return _public_write_result(
        $self->_run_store(
            'post not found',
            sub { return $self->_delete_once($input); },
        )
    );
}

sub _commanded_write ( $self, $job ) {
    if ( !$self->command_idempotency ) {
        return $job->{run}->();
    }

    return $self->_idempotent_write($job);
}

sub _idempotent_write ( $self, $job ) {
    my $result = eval { return $self->command_idempotency->result_of($job); };
    if ($EVAL_ERROR) {
        $self->_log_error("attachment command log failed: $EVAL_ERROR");
        return _failed_result();
    }

    return $result;
}

sub _missing_command_id ( $, $input ) {
    if ( length _trim( $input->{command_id} ) ) {
        my $undefined;
        return $undefined;
    }

    return _result(
        errors => { command_id => 'command_id is required' },
        status => 'invalid',
    );
}

sub _public_write_result ($result) {
    if ( !$result->{ok} ) {
        return $result;
    }

    return _result(
        status => $result->{status},
        stored => _public_stored( $result->{stored} ),
    );
}

sub _public_stored ($stored) {
    my $public = { ok => $stored->{ok}, };
    $public->{attachment} = _public_attachment( $stored->{attachment} );
    $public->{idempotent} = $stored->{idempotent};
    $public->{link}       = _public_link( $stored->{link} );
    $public->{post}       = _public_post( $stored->{post} );

    return $public;
}

sub _public_attachment ($attachment) {
    if ( !$attachment ) {
        my $undefined;
        return $undefined;
    }

    return {
        attachment_id     => _column( $attachment, 'attachment_id' ),
        byte_size         => _column( $attachment, 'byte_size' ),
        media_type        => _column( $attachment, 'media_type' ),
        original_filename => _column( $attachment, 'original_filename' ),
        scan_status       => _column( $attachment, 'scan_status' ),
        state             => _column( $attachment, 'state' ),
    };
}

sub _public_link ($link) {
    if ( !$link ) {
        my $undefined;
        return $undefined;
    }

    return {
        attachment_id      => _column( $link, 'attachment_id' ),
        attachment_link_id => _column( $link, 'attachment_link_id' ),
        target_id          => _column( $link, 'target_id' ),
        target_type        => _column( $link, 'target_type' ),
    };
}

sub _public_post ($post) {
    if ( !$post ) {
        my $undefined;
        return $undefined;
    }

    return {
        post_id   => _column( $post, 'post_id' ),
        thread_id => _column( $post, 'thread_id' ),
    };
}

sub _failed_result {
    return _result(
        error  => 'attachment store failed',
        status => 'failed',
    );
}

sub _trim ($value) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _delete_once ( $self, $input ) {
    my $post = $self->post_reader->find_visible_post( $input->{post_id},
        $input->{viewer} );
    if ( !$post ) {
        my $undefined;
        return $undefined;
    }
    if ( !_same_author( $post, $input->{actor_user_id} ) ) {
        return {
            error     => 'post author required',
            forbidden => 1,
        };
    }

    return _linked_delete(
        $self->store->delete_linked(
            {
                actor_id      => $input->{actor_user_id},
                attachment_id => $input->{attachment_id},
                target_id     => _column( $post, 'post_id' ),
                target_type   => 'post',
            }
        ),
        $post,
    );
}

sub _download_once ( $self, $input ) {
    return $self->delivery->download(
        {
            attachment_id  => $input->{attachment_id},
            viewer         => $input->{viewer},
            viewer_user_id => $input->{viewer_user_id},
        }
    );
}

sub _linked_upload ( $uploaded, $post ) {
    if ( !$uploaded ) {
        my $undefined;
        return $undefined;
    }
    if ( !$uploaded->{ok} ) {
        return {
            errors  => $uploaded->{errors} || {},
            invalid => 1,
        };
    }

    return { %{$uploaded}, post => $post, };
}

sub _linked_delete ( $deleted, $post ) {
    if ( !$deleted ) {
        my $undefined;
        return $undefined;
    }
    if ( !$deleted->{ok} ) {
        return $deleted;
    }

    return { %{$deleted}, post => $post, };
}

sub _same_author ( $post, $user_id ) {
    return ( _column( $post, 'author_user_id' ) || q{} ) eq ( $user_id || q{} );
}

sub _run_store ( $self, $not_found, $code ) {
    my $stored = $self->_eval_store($code);
    if ( $stored->{failed} ) {
        return _result(
            error  => 'attachment store failed',
            status => 'failed',
        );
    }

    return _stored_result( $not_found, $stored->{value} );
}

sub _eval_store ( $self, $code ) {
    my $value = eval { return $code->(); };
    if ($EVAL_ERROR) {
        $self->_log_error("attachment write failed: $EVAL_ERROR");
        return { failed => 1 };
    }

    return { value => $value };
}

sub _stored_result ( $not_found, $value ) {
    if ( !$value ) {
        return _result(
            error  => $not_found,
            status => 'not_found',
        );
    }

    return _classified_result($value);
}

sub _classified_result ($value) {
    my $denied = _denied_result($value);
    if ($denied) {
        return $denied;
    }

    return _result(
        status => 'ok',
        stored => $value,
    );
}

sub _denied_result ($value) {
    my $tagged = _tagged_denial($value);
    if ($tagged) {
        return $tagged;
    }

    return _store_denial($value);
}

sub _tagged_denial ($value) {
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

    my $undefined;
    return $undefined;
}

sub _store_denial ($value) {
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

    my $undefined;
    return $undefined;
}

sub _is_missing ($value) {
    if ( !_has_ok($value) ) {
        return 0;
    }

    return $value->{ok} ? 0 : ( $value->{error} || q{} ) eq 'not_found';
}

sub _is_denied ($value) {
    if ( !_has_ok($value) ) {
        return 0;
    }

    return $value->{ok} ? 0 : 1;
}

sub _has_ok ($value) {
    if ( ref $value ne 'HASH' ) {
        return 0;
    }

    return exists $value->{ok} ? 1 : 0;
}

sub _column ( $row, $name ) {
    if ( !$row ) {
        my $undefined;
        return $undefined;
    }
    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }

    return _object_column( $row, $name );
}

sub _object_column ( $row, $name ) {
    if ( $row->can('get_column') ) {
        return $row->get_column($name);
    }

    my $undefined;
    return $undefined;
}

sub _result (%input) {
    return {
        error  => $input{error},
        errors => $input{errors},
        ok     => ( $input{status} || q{} ) eq 'ok' ? 1 : 0,
        status => $input{status} || 'failed',
        stored => $input{stored},
    };
}

sub _log_error ( $self, $message ) {
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

Application boundary for post attachment uploads, author deletes, and
attachment downloads.
Looks up a visible post, enforces author ownership, and delegates binary
storage to the existing upload pipeline and delivery service. Upload and
delete require C<command_id> and replay from C<command_log> when the
helper is present. Command hashes include actor and target ids only, never
the uploaded bytes. Returns a normalized JSON-safe result hash. Stores
keep transaction, event, audit, and object storage ownership.

=head1 SUBROUTINES/METHODS

=head2 upload_for_post

Uploads and links an attachment to a visible post owned by the actor.
Requires C<command_id>.

=head2 delete_for_post

Soft-deletes an attachment linked to a visible post owned by the actor.
Already-deleted rows replay as success. Requires C<command_id>.

=head2 download

Delivers attachment bytes for an authorized viewer.

=head1 DIAGNOSTICS

Returns C<invalid>, C<not_found>, C<forbidden>, C<conflict>, or C<failed>
statuses instead of throwing for expected outcomes. Unexpected store
exceptions are logged and mapped to C<failed>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses post reader, upload pipeline, attachment store, and delivery services
supplied by the composition root.

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
