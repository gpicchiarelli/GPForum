# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::File qw(path);
use Test::Mojo;
use Test::More;

use lib 'lib';

use GPForum::Service::Attachment::Validator;

our $VERSION = '0.001';

const my $MEBIBYTE => 1_024 * 1_024;

# GPForum accepts attachments up to 25 MiB, and nginx was raised to 26 MiB so
# it would stop answering 413 below that. Mojolicious cuts a request off at
# 16 MiB unless told otherwise, so an upload between 16 and 25 MiB still
# never reached the attachment validator.

my $t       = Test::Mojo->new('GPForum');
my $largest = GPForum::Service::Attachment::Validator->max_bytes;

subtest 'the application takes a request as large as an attachment' => sub {
    cmp_ok( $t->app->max_request_size,
        '>', $largest,
        'more than the largest attachment, for the form around it' );

    for my $nginx (
        qw(deploy/nginx/gpforum.conf deploy/nginx/gpforum-unix-socket.conf))
    {
        my ($megabytes) =
          path($nginx)->slurp =~ /^ \s* client_max_body_size [ ] (\d+)m;/msx;
        is(
            $t->app->max_request_size,
            $megabytes * $MEBIBYTE,
            "and as much as $nginx lets through"
        );
    }
};

subtest 'an upload at the limit reaches the application whole' => sub {
    my $exceeded;
    $t->app->hook(
        before_dispatch => sub ($c) {
            $exceeded = $c->req->is_limit_exceeded ? 1 : 0;
        }
    );

    $t->post_ok( '/login' => form =>
          { upload => { content => 'x' x $largest, filename => 'a.bin' } } );
    is( $exceeded, 0, 'a 25 MiB attachment is read in full' );

    $t->post_ok(
        '/login' => form => {
            upload => {
                content  => 'x' x ( $largest + 2 * $MEBIBYTE ),
                filename => 'a.bin'
            }
        }
    );
    is( $exceeded, 1, 'and a larger request is still cut off' );
};

done_testing();

1;
