# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';

use GPForum::OS;
use GPForum::Service::Operations::ServiceAccount;

our $VERSION = '0.001';

const my $PRIVATE   => oct '750';
const my $MODE_BITS => oct '777';
const my $FREE_ID   => 499;

# ADR 0122: gpforum setup, run as root, makes the account the services run
# as where the system has one command for it -- useradd on Linux, pw on
# FreeBSD -- and on macOS says to make it by hand.

my $class = 'GPForum::Service::Operations::ServiceAccount';

subtest q{each system's command, or none} => sub {
    is_deeply(
        $class->new( os => GPForum::OS->from_name('linux') )
          ->commands('/opt/gpforum'),
        [
            [
                qw(useradd --system --user-group --home-dir /opt/gpforum),
                qw(--shell /usr/sbin/nologin gpforum)
            ]
        ],
        q{Linux: useradd, as docs/DEPLOYMENT.md typed it}
    );
    is_deeply(
        $class->new( os => GPForum::OS->from_name('freebsd') )
          ->commands('/usr/local/www/gpforum'),
        [
            [
                qw(pw useradd gpforum -d /usr/local/www/gpforum),
                qw(-s /usr/sbin/nologin -c GPForum)
            ]
        ],
        'FreeBSD: pw, which makes the group too'
    );
    my $mac = GPForum::OS->from_name('darwin')->account_id($FREE_ID);
    is_deeply(
        $class->new( os => $mac )->commands('/opt/gpforum'),
        [
            (
                map { [ qw(dscl . -create /Groups/gpforum), @{$_} ] }
                  [ 'PrimaryGroupID', $FREE_ID ],
                [qw(RealName GPForum)],
                [ 'Password', q{*} ]
            ),
            (
                map { [ qw(dscl . -create /Users/gpforum), @{$_} ] }
                  [ 'UniqueID', $FREE_ID ],
                [ 'PrimaryGroupID', $FREE_ID ],
                [qw(UserShell /usr/bin/false)],
                [qw(NFSHomeDirectory /var/empty)],
                [qw(RealName GPForum)],
                [ 'Password', q{*} ],
                [qw(IsHidden 1)]
            ),
        ],
        'macOS: dscl, the group and the account under one free id'
    );
    is_deeply(
        $class->new(
            os => GPForum::OS->from_name('darwin')->account_id(undef)
        )->commands('/opt/gpforum'),
        [],
        'and none when every id under 500 is taken'
    );
};

subtest 'the commands are run, and a failure says which' => sub {
    my @ran;
    my $account = $class->new(
        os  => GPForum::OS->from_name('linux'),
        run => sub (@command) { push @ran, [@command]; return undef; },
    );
    is( $account->make('/opt/gpforum'), undef,     'made' );
    is( $ran[0][0],                     'useradd', 'with useradd' );

    my $failed = $class->new(
        os  => GPForum::OS->from_name('linux'),
        run => sub (@command) { return 'it exited 9'; },
    )->make('/opt/gpforum');
    like(
        $failed->{command},
        qr/\A useradd [ ] --system/msx,
        'the command that failed'
    );
    is( $failed->{reason}, 'it exited 9', 'and why' );
};

subtest 'the uploads directory is made for the account' => sub {
    my $name    = getpwuid $EFFECTIVE_USER_ID;
    my $account = $class->new( name => $name );
    my ( $uid, $gid ) = $account->ids;
    is( $uid, $EFFECTIVE_USER_ID, q{an account's ids} );

    my $root = tempdir( CLEANUP => 1 );
    my $made = $account->make_directory("$root/var/attachments");
    is_deeply(
        $made,
        [ "$root/var", "$root/var/attachments" ],
        'each directory missing, from the top'
    );
    is( ( stat "$root/var/attachments" )[2] & $MODE_BITS,
        $PRIVATE, 'readable by its group and nobody else' );
    is_deeply( $account->make_directory("$root/var/attachments"),
        [], 'and nothing the second time' );

    ok(
        !$class->new( name => 'no-such-account-530' )->ids,
        'an account that does not exist has no ids'
    );
};

done_testing();

1;
