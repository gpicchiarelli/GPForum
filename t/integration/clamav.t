# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Infrastructure::Antivirus::Clamd;
use GPForum::Service::Attachment::DownloadAccess;
use GPForum::Service::Operations::AntivirusCheck;
use GPForum::Test::AttachmentFixtures;

our $VERSION = '0.001';

const my $LARGE_BYTES => 5 * 1_024 * 1_024;

# ADR 0108 against a real clamd: the one the operating system's package runs,
# or in CI one started with a test signature. Nothing here is faked.
if ( !$ENV{GPFORUM_CLAMD_SOCKET} ) {
    plan skip_all => 'set GPFORUM_CLAMD_SOCKET to run against a real clamd';
}

my $clamd = GPForum::Infrastructure::Antivirus::Clamd->new(
    socket_path => $ENV{GPFORUM_CLAMD_SOCKET} );
my $eicar = GPForum::Service::Operations::AntivirusCheck->test_file;

ok( $clamd->ping, 'clamd answers PING' );
like( $clamd->version->{engine}, qr/ClamAV/msx, 'and reports its engine' );

my $found = $clamd->scan($eicar);
is( $found->{status}, 'infected', 'the EICAR test file is detected' );
like( $found->{signature}, qr/eicar/imsx, 'by name' );
is( $clamd->scan("an ordinary file\n")->{status},
    'clean', 'an ordinary file is clean' );
is( $clamd->scan( 'x' x $LARGE_BYTES )->{status},
    'clean', 'a multi-megabyte stream fits clamd\'s StreamMaxLength' );

# End to end. EICAR is printable text, so the media type check passes it as
# text/plain; only the antivirus stands between it and the forum.
my $fixture  = GPForum::Test::AttachmentFixtures->build( antivirus => $clamd );
my $uploaded = $fixture->{pipeline}->upload_and_link(
    {
        actor_user_id     => 'user-1',
        content           => $eicar,
        media_type        => 'text/plain',
        original_filename => 'notes.txt',
        target_id         => 'post-99',
        target_type       => 'post',
    }
);
my $row =
  $fixture->{store}->find_attachment( $uploaded->{attachment}{attachment_id} );
is( $row->get_column('scan_status'),
    'infected', 'an upload carrying EICAR is recorded infected' );
ok( !GPForum::Service::Attachment::DownloadAccess->new->downloadable($row),
    'and is never served' );

my $check = GPForum::Service::Operations::AntivirusCheck->new(
    config => GPForum::Config->new(
        antivirus        => 'clamd',
        antivirus_socket => $ENV{GPFORUM_CLAMD_SOCKET},
    )
)->run;
is( $check->{test_file}{status},
    'infected', 'bin/gpforum-antivirus-check proves detection' );
is_deeply( $check->{problems}, [], 'with no problems' );

done_testing();

1;
