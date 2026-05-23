package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use File::Spec;
use File::Temp qw(tempdir);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::OS;
use GPForum::OS::Filesystem;

our $VERSION = '0.001';

const my $EXPECTED_TESTS      => 12;
const my $FAILED_OPEN_COUNTER => 3;

plan tests => $EXPECTED_TESTS;

my $directory  = tempdir( CLEANUP => 1 );
my $target     = File::Spec->catfile( $directory, 'artifact.txt' );
my $filesystem = GPForum::OS::Filesystem->new;

my $first = $filesystem->write_atomic( $target, 'first version' );
ok( $first->{ok}, 'atomic write reports success' );
is( _slurp($target), 'first version', 'atomic write creates target content' );
ok( !-e $first->{temporary_path}, 'temporary file is removed after rename' );

my $replacement = $filesystem->write_atomic( $target, 'second version' );
ok( $replacement->{ok}, 'second atomic write reports success' );
is( _slurp($target), 'second version', 'atomic write replaces target content' );
ok( !-e $replacement->{temporary_path}, 'second temporary file is removed' );
isnt(
    $first->{temporary_path},
    $replacement->{temporary_path},
    'temporary paths are unique per writer'
);

throws_ok(
    sub {
        $filesystem->write_atomic( q{}, 'content' );
    },
    qr/\A path [ ] is [ ] required/msx,
    'empty path is rejected'
);

throws_ok(
    sub {
        $filesystem->write_atomic( $target, undef );
    },
    qr/\A content [ ] is [ ] required/msx,
    'undefined content is rejected'
);

my $missing_target = File::Spec->catfile( $directory, 'missing', 'file.txt' );
throws_ok(
    sub {
        $filesystem->write_atomic( $missing_target, 'content' );
    },
    qr/failed [ ] to [ ] open [ ] temporary [ ] file/msx,
    'missing parent directory fails clearly'
);

my $os = GPForum::OS->from_name('unknown');
ok(
    $os->filesystem->isa('GPForum::OS::Filesystem'),
    'OS profile exposes filesystem helper'
);
ok(
    !-e join( q{.}, $missing_target, $PROCESS_ID, $FAILED_OPEN_COUNTER, 'tmp' ),
    'failed open does not leave known temp file'
);

sub _slurp {
    my ($path) = @_;

    open my $handle, '<', $path or croak "failed to read $path: $ERRNO";
    local $INPUT_RECORD_SEPARATOR = undef;
    my $content = <$handle>;
    close $handle or croak "failed to close $path: $ERRNO";

    return $content;
}

1;
