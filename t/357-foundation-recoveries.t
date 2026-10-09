# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojolicious;
use Test::More;
use Time::HiRes qw(time);

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Operations;
use GPForum::Bootstrap::Workers;
use GPForum::Config;
use GPForum::Infrastructure::Antivirus::Command;
use GPForum::Infrastructure::PgNotifications;
use GPForum::OS::Filesystem;
use GPForum::OS::RuntimeEvidence;
use GPForum::Test::FeedProjector;
use GPForum::Test::FixedClock;
use GPForum::Test::RealtimeBusSchema;
use GPForum::Test::UnlistenRefusingDbh;
use GPForum::Worker::Handler::FeedProjection;
use GPForum::X::Config;

our $VERSION = '0.001';

const my $SCANNER_TIMEOUT => 1;
const my $PROMPT_SECONDS  => 10;

# The foundation's catch blocks each decide what a failure becomes: an
# answer, a rethrow or a cleanup. Each case here breaks the code under it
# when the catch is changed, which the rest of the suite did not.

subtest 'a projection is dated by the event, then the clock' => sub {
    my $projector = GPForum::Test::FeedProjector->new;
    my $handler   = GPForum::Worker::Handler::FeedProjection->new(
        clock     => GPForum::Test::FixedClock->new,
        projector => $projector,
    );
    my %post = (
        actor_id     => 'user-1',
        aggregate_id => 'post-1',
        event_id     => 'event-1',
        event_type   => 'post.created',
    );

    $handler->handle(
        {
            %post,
            occurred_at => '2026-01-02T00:00:00Z',
            timestamp   => '2026-01-01T00:00:00Z',
        }
    );
    $handler->handle( { %post, occurred_at => '2026-01-02T00:00:00Z' } );
    $handler->handle( {%post} );

    is_deeply(
        [ map { $_->{created_at} } @{ $projector->calls } ],
        [
            '2026-01-01T00:00:00Z',
            '2026-01-02T00:00:00Z',
            GPForum::Test::FixedClock->new->now_iso8601,
        ],
        'the timestamp first, then occurred_at, then now'
    );
};

subtest 'an atomic write that cannot be renamed leaves nothing behind' => sub {
    my $directory = tempdir( CLEANUP => 1 );
    my $target    = "$directory/target";
    mkdir $target or BAIL_OUT("mkdir $target");
    GPForum::OS::Filesystem->new->write_atomic( "$target/inside", 'kept' );

    my $error = _error_of(
        sub { GPForum::OS::Filesystem->new->write_atomic( $target, 'bytes' ) }
    );
    like(
        $error,
        qr/\A failed [ ] to [ ] rename/msx,
        'a rename onto a directory fails'
    );
    opendir my $handle, $directory or BAIL_OUT("opendir $directory");
    my @remaining = sort grep { !/\A [.]{1,2} \z/msx } readdir $handle;
    closedir $handle or BAIL_OUT("closedir $directory");
    is_deeply( \@remaining, ['target'], 'and its temporary file is removed' );
};

subtest 'a scanner command that outlasts its timeout is killed' => sub {
    my $scanner = GPForum::Infrastructure::Antivirus::Command->new(
        command         => [ $EXECUTABLE_NAME, '-e', 'sleep 30' ],
        timeout_seconds => $SCANNER_TIMEOUT,
    );

    my $started = time;
    my $verdict = $scanner->scan('bytes');
    is( $verdict->{status}, 'error', 'the scan is an error, never clean' );
    like( $verdict->{error}, qr/timed [ ] out/msx, 'saying it timed out' );
    cmp_ok( time - $started,
        q{<}, $PROMPT_SECONDS, 'without waiting for the command to finish' );
};

subtest 'an UNLISTEN that fails is reported as not undone' => sub {
    my $dbh           = GPForum::Test::UnlistenRefusingDbh->new;
    my $notifications = GPForum::Infrastructure::PgNotifications->new(
        schema => GPForum::Test::RealtimeBusSchema->new( dbh => $dbh ) );

    ok( $notifications->listen_to('gpforum_cache'), 'listening' );
    $dbh->refuse_unlisten(1);
    is( $notifications->unlisten('gpforum_cache'),
        0, 'a failed UNLISTEN answers 0' );

    $dbh->refuse_unlisten(0);
    ok( $notifications->listen_to('gpforum_cache'), 'listening again' );
    is( $notifications->unlisten('gpforum_cache'),
        1, 'and one that runs answers 1' );
};

subtest 'an optional helper that fails is not taken for a missing one' => sub {
    my $application = Mojolicious->new;
    $application->helper( gp_broken => sub { die "database down\n" } );
    my $controller = $application->build_controller;

    is( _optional_helper( $controller, 'gp_absent' ),
        undef, 'a helper that is not registered is undef' );
    is(
        _error_of(
            sub {
                _optional_helper( $controller, 'gp_broken' );
            }
        ),
        "database down\n",
        'one that dies is rethrown'
    );
};

subtest
  'a Minion backend whose modules do not load is a configuration error' => sub {
    my $blocked = 'Minion/Backend/Pg.pm';
    delete local $INC{$blocked};
    local @INC = (
        sub {
            my ( undef, $file ) = @_;
            die "blocked for the test\n" if $file eq $blocked;

            return;
        },
        @INC
    );

    my $error = _error_of(
        sub {
            _require_minion_backend(
                GPForum::Config->new(
                    minion_pg_url => 'postgresql://localhost/minion'
                )
            );
        }
    );
    ok( GPForum::X::Config->caught($error), 'raised as X::Config' );
    like( "$error", qr/requires [ ] Mojo::Pg/msx, 'naming what to install' );
    like(
        $error && $error->cause,
        qr/blocked [ ] for [ ] the [ ] test/msx,
        'carrying the load error'
    );
  };

subtest 'a module that is on disk but does not compile is unavailable' => sub {
    my $directory = tempdir( CLEANUP => 1 );
    mkdir "$directory/GPForumProbe" or BAIL_OUT('mkdir GPForumProbe');
    open my $handle, '>', "$directory/GPForumProbe/Broken.pm"
      or BAIL_OUT('open Broken.pm');
    print {$handle} "die qq{broken on purpose\\n};\n"
      or BAIL_OUT('write Broken.pm');
    close $handle or BAIL_OUT('close Broken.pm');
    local @INC = ( $directory, @INC );

    is( _module_available('GPForumProbe::Broken'),
        0, 'a module that dies while loading is unavailable' );
    is( _module_available('Mojo::Base'), 1, 'one that loads is available' );
};

done_testing();

sub _error_of {
    my ($code) = @_;

    try {
        $code->();
    }
    catch ($error) {
        return $error;
    };

    return undef;
}

# The private steps these cases pin, called where they live: none is
# reachable on its own without a running application or a broken install.
sub _optional_helper {
    my (@arguments) = @_;

    ## no critic (Subroutines::ProtectPrivateSubs)
    return GPForum::Bootstrap::Operations::_optional_controller_helper(
        @arguments);
}

sub _require_minion_backend {
    my ($config) = @_;

    ## no critic (Subroutines::ProtectPrivateSubs)
    return GPForum::Bootstrap::Workers::_require_minion_backend($config);
}

sub _module_available {
    my ($module) = @_;

    ## no critic (Subroutines::ProtectPrivateSubs)
    return GPForum::OS::RuntimeEvidence::_module_available($module);
}

1;
