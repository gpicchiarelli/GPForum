# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Digest::SHA qw(sha256_hex);
use Test::More;

use lib 'lib';

use GPForum::Service::Forum::PostingCommand;

our $VERSION = '0.001';

# The codec's own edges. t/325 pins what it encodes for every command type
# and path of the workflow, byte for byte.

my $codec = GPForum::Service::Forum::PostingCommand->new;

is_deeply(
    $codec->types,
    [
        qw(post.delete post.edit post.restore reply.create thread.create
          thread.delete thread.edit thread.move thread.restore)
    ],
    'the nine posting command types'
);

is( $codec->body_hash(" body \n"),
    sha256_hex('body'), 'the body hash is of the trimmed source' );
is( $codec->body_hash(undef),
    sha256_hex(q{}), 'an undefined body hashes as empty' );

is_deeply(
    $codec->request(
        'post.edit',
        {
            author_user_id => undef,
            body_source    => ' x ',
            command_id     => 'c-1',
            edit_reason    => 'typo',
            post_id        => ' post-1 ',
            viewer         => 'someone',
        }
    ),
    {
        author_user_id => q{},
        body_hash      => sha256_hex('x'),
        post_id        => 'post-1',
    },
    'a request keeps its fields trimmed, undef as empty, and nothing else'
);

is_deeply(
    $codec->response( 'thread.move', { ok => 0, error => q{} } ),
    { ok => 0, status => 'failed' },
    'a result without a status or an error is a failure with no error'
);

is_deeply(
    $codec->replay( 'thread.edit', { ok => 0, status => 'forbidden' } ),
    {
        error      => undef,
        idempotent => 1,
        ok         => 0,
        prepared   => undef,
        status     => 'forbidden',
        stored     => undef,
    },
    'a refusal replays with nothing stored'
);

is_deeply(
    $codec->replay( 'reply.create', { ok => 1, status => 'ok' } )->{stored},
    { ok => 1, post => { post_id => undef, thread_id => undef } },
    'a success replays the stored rows from whatever the response kept'
);

my $error;
try { $codec->request( 'post.burn', {} ); }
catch ($caught) { $error = $caught; };
isa_ok( $error, 'GPForum::X::Argument', 'an unknown command type' );
like(
    "$error",
    qr/\Aunknown[ ]posting[ ]command[ ]type:[ ]post[.]burn\z/msx,
    'the unknown type is named'
);

done_testing();

1;
