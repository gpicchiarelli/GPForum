# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';

use GPForum::Service::Attachment::Validator;

our $VERSION = '0.001';

# The validator names an upload by its first bytes, never by what the client
# claims. A WebP file is a RIFF container: "RIFF", a four-byte size, "WEBP".
my $validator = GPForum::Service::Attachment::Validator->new;

for my $case (
    [ '89504e470d0a1a0a72657374',       'image/png',       'a PNG' ],
    [ 'ffd8ffe0',                       'image/jpeg',      'a JPEG' ],
    [ '474946383961',                   'image/gif',       'a GIF' ],
    [ '255044462d312e37',               'application/pdf', 'a PDF' ],
    [ '524946462400000057454250565038', 'image/webp',      'a WebP' ],
    [ '524946460a00000057454250', 'image/webp', 'a WebP of twelve bytes' ],
    [
        '524946462400000057415645666d74', 'application/octet-stream',
        'a WAVE is not a WebP'
    ],
    [
        '52494646000057454250', 'application/octet-stream',
        'nor a RIFF with a short size'
    ],
    [ '706c61696e20776f726473', 'text/plain',               'text' ],
    [ '00010203fe',             'application/octet-stream', 'anything else' ],
  )
{
    my ( $hex, $expected, $name ) = @{$case};
    is( $validator->sniff_media_type( pack 'H*', $hex ),
        $expected, "$name is $expected" );
}
is( $validator->sniff_media_type(undef), undef, 'no content is no type' );

done_testing();

1;
