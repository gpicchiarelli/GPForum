# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::PostingCommand;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::X::Argument;

our $VERSION = '0.001';

# What the command log keeps of each posting command, by command type:
# - request: the input fields of its fingerprint, trimmed; body_hash is the
#   SHA-256 of the trimmed body_source.
# - stored: on success, the fields of each stored row the response keeps
#   (flat, under the field's name) and a replay rebuilds (under the row).
# Both are part of the command log's contract with every command recorded
# before a change: a changed request turns a retry into a conflict, and a
# changed response answers a retry differently from its first run.
const my %POST_STORED => ( post => [qw(post_id thread_id)] );
const my %COMMAND => (
    'thread.create' => {
        request => [qw(author_user_id body_hash category_id title visibility)],
        stored  => { post => ['post_id'], thread => ['thread_id'] },
    },
    'reply.create' => {
        request => [qw(author_user_id body_hash thread_id visibility)],
        stored  => \%POST_STORED,
    },
    'post.edit' => {
        request => [qw(author_user_id body_hash post_id)],
        stored  => \%POST_STORED,
    },
    'post.delete' => {
        request => [qw(author_user_id post_id)],
        stored  => \%POST_STORED,
    },
    'post.restore' => {
        request => [qw(author_user_id post_id)],
        stored  => \%POST_STORED,
    },
    'thread.edit' => {
        request => [qw(author_user_id thread_id title)],
        stored  => { thread => [qw(slug thread_id title)] },
    },
    'thread.move' => {
        request => [qw(author_user_id category_id thread_id)],
        stored  => { thread => [qw(category_id thread_id)] },
    },
    'thread.delete' => {
        request => [qw(author_user_id thread_id)],
        stored  => { thread => ['thread_id'] },
    },
    'thread.restore' => {
        request => [qw(author_user_id thread_id)],
        stored  => { thread => ['thread_id'] },
    },
);

sub types ($self) {
    return [ sort keys %COMMAND ];
}

sub request ( $self, $type, $input ) {
    return {
        map {
                $_ => $_ eq 'body_hash'
              ? $self->body_hash( $input->{body_source} )
              : _trim( $input->{$_} )
        } @{ _command($type)->{request} }
    };
}

sub response ( $self, $type, $result ) {
    my $response = {
        ok     => $result->{ok} ? 1 : 0,
        status => $result->{status} || 'failed',
    };
    if ( defined $result->{error} && length $result->{error} ) {
        $response->{error} = $result->{error};
    }
    if ( $result->{ok} ) {
        my $stored = _command($type)->{stored};
        for my $row ( keys %{$stored} ) {
            for my $field ( @{ $stored->{$row} } ) {
                $response->{$field} =
                  _column( $result->{stored}{$row}, $field );
            }
        }
    }
    if ( _invalid($result) ) {
        $response->{errors} = $result->{prepared}{errors} || {};
        $response->{values} = $result->{prepared}{values} || {};
    }

    return $response;
}

sub replay ( $self, $type, $response ) {
    my $stored;
    if ( $response->{ok} ) {
        my $spec = _command($type)->{stored};
        $stored = { ok => 1 };
        for my $row ( keys %{$spec} ) {
            $stored->{$row} =
              { map { $_ => $response->{$_} } @{ $spec->{$row} } };
        }
    }

    return {
        error      => $response->{error},
        idempotent => 1,
        ok         => ( $response->{status} || q{} ) eq 'ok' ? 1 : 0,
        prepared   => _invalid($response)
        ? {
            errors => $response->{errors} || {},
            ok     => 0,
            values => $response->{values} || {},
          }
        : undef,
        status => $response->{status} || 'failed',
        stored => $stored,
    };
}

sub body_hash ( $self, $body_source ) {
    return sha256_hex( _trim($body_source) );
}

sub _command ($type) {
    if ( !exists $COMMAND{ $type // q{} } ) {
        GPForum::X::Argument->throw(
            message => 'unknown posting command type: ' . ( $type // q{} ) );
    }

    return $COMMAND{$type};
}

sub _invalid ($answer) {
    return ( $answer->{status} || q{} ) eq 'invalid' ? 1 : 0;
}

sub _trim ($value) {
    return ( $value // q{} ) =~ s/\A \s+ | \s+ \z//grmsx;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::PostingCommand - What the command log keeps of a posting command: its request, its response and their replay.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $codec = GPForum::Service::Forum::PostingCommand->new;

    my $request  = $codec->request( 'post.edit', $input );
    my $response = $codec->response( 'post.edit', $result );

    # A repeat of the same request, answered from the log:
    my $replayed = $codec->replay( 'post.edit', $response );

=head1 DESCRIPTION

L<GPForum::Service::Forum::PostingWorkflow> runs each of its nine commands
through L<GPForum::Service::Operations::CommandIdempotency>, which keeps a
fingerprint of the request and the response, and answers a repeat of the
same request from the response. This module is that encoding, one table
keyed by command type, with no state and no collaborators.

The encoding is a contract with every command already in the log: a
request encoded differently turns a retry of an earlier command into a
conflict, and a response or replay encoded differently answers a retry
differently from its first run. C<t/325-forum-posting-golden.t> pins it
byte for byte.

    type            request fields                             stored rows
    thread.create   author_user_id body_hash category_id       thread: thread_id
                    title visibility                           post: post_id
    reply.create    author_user_id body_hash thread_id         post: post_id
                    visibility                                       thread_id
    post.edit       author_user_id body_hash post_id           post: post_id
                                                                     thread_id
    post.delete     author_user_id post_id                     post: post_id
    post.restore                                                     thread_id
    thread.edit     author_user_id thread_id title             thread: slug
                                                               thread_id title
    thread.move     author_user_id category_id thread_id       thread:
                                                               category_id
                                                               thread_id
    thread.delete   author_user_id thread_id                   thread:
    thread.restore                                             thread_id

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor; it has no attributes.

=head2 types

Returns the nine command types, sorted, as an array reference.

=head2 request

Takes a command type and the workflow's input. Returns the request
fingerprint: each request field of the type, trimmed of surrounding
whitespace (undef as empty), with C<body_hash> the L</body_hash> of
C<body_source>. Nothing else of the input is kept: not the C<viewer>, not
an C<edit_reason>, not the command id.

=head2 response

Takes a command type and the workflow's result. Returns
C<< { ok => 1 or 0, status => STATUS } >> (status C<failed> when the
result has none), plus C<error> when the result's is non-empty; on success
each field of each stored row of the type, read from the result's
C<stored> row of that name and kept flat under the field's name; and for
an C<invalid> result the composer's C<errors> and C<values> (empty hashes
when missing).

=head2 replay

Takes a command type and a response kept by L</response>. Returns the
result the workflow answers a repeat with: C<error>, C<idempotent> 1, C<ok>
(1 only for status C<ok>), C<status> (C<failed> when missing), C<prepared>
rebuilt as C<< { ok => 0, errors, values } >> for an C<invalid> response
and undef otherwise, and C<stored> rebuilt for a successful response as
C<< { ok => 1, ROW => { FIELD => value } } >> from the type's stored rows,
undef otherwise. A replay holds only those ids and fields, not the rows of
the first run.

=head2 body_hash

Takes a body source and returns the hex SHA-256 of it trimmed (undef as
empty).

=head1 DIAGNOSTICS

A command type other than the nine above throws L<GPForum::X::Argument>
(C<unknown posting command type: TYPE>).

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<Const::Fast>, L<Digest::SHA>,
L<GPForum::Infrastructure::Row>, L<GPForum::X::Argument>.

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
