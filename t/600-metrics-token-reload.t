# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Mojo::Headers;
use Mojo::Log;
use Test::Mojo;
use POSIX       qw(_exit);
use Time::HiRes qw(sleep);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Secret;
use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Config;
use GPForum::Service::Operations::MetricsTokens;
use GPForum::Test::CountingParser;
use GPForum::Test::MetricsSnapshot;
use GPForum::Test::ReadyHealth;
use GPForum::Web::OperationsAccess;

our $VERSION = '0.001';

# Owner decision, 2026-10-10: a metrics-token rotation is three commands --
# gpforum secret rotate metrics, the scrapers' new token, --finish -- with no
# restart, because the running service reads the accepted tokens from its
# environment file again (ADR 0124). Walkthrough 3 (friction 6) counted
# four: rotate, restart, --finish, restart. These hold the service to the
# file, and hold the file to what may never happen: the tokens becoming
# none, which would open /metrics to anyone.

const my $SECRET_FILE_MODE  => oct '640';
const my $GROUP_WRITABLE    => oct '660';
const my $TOKEN_LENGTH      => 64;
const my $CHECKS            => 10;
const my $FIRST             => 'a' x $TOKEN_LENGTH;
const my $OTHER_FORUM       => 'f' x $TOKEN_LENGTH;
const my $ROTATIONS         => 30;
const my $IN_PLACE_WRITES   => 30;
const my $PAUSE             => 0.002;
const my $CHILD_FAILED      => 1;
const my $EXIT_SHIFT        => 8;
const my $HTTP_OK           => 200;
const my $HTTP_UNAUTHORIZED => 401;
const my $LONGEST_WAIT_SECS => 30;

local $ENV{LC_ALL} = 'en_US.UTF-8';

my $directory = tempdir( CLEANUP => 1 );
my $access    = GPForum::Web::OperationsAccess->new;

subtest 'a rotation and its finish take effect with no restart' =>
  \&_rotation_needs_no_restart;
subtest 'the application follows the file it started with' =>
  \&_application_follows_its_file;
subtest 'an unchanged file is not read again' => \&_unchanged_file_not_read;
subtest 'never none: what the service cannot use leaves the tokens' =>
  \&_never_none;
subtest 'a file with other tokens than the start is not followed' =>
  \&_other_tokens_not_followed;
subtest 'a configuration not watched keeps its own list' =>
  \&_unwatched_keeps_its_list;
subtest 'GPFORUM_ENV_FILE names the file a service file gave' =>
  \&_declared_file;
subtest 'the session secret is not read again' => \&_session_secret_not_read;
subtest 'scrapes during rotations are never refused, nor opened' =>
  \&_scrapes_during_rotations;
subtest 'a file written in place, a piece at a time, never opens it' =>
  \&_written_in_place;

done_testing();

sub _rotation_needs_no_restart {
    my $file    = _file( 'live.env', $FIRST );
    my $watched = _watch($file);
    my $config  = $watched->{config};
    ok( $watched->{tokens}->following, 'the file the service started with' );
    ok( _scraped( $config, $FIRST ),   'the first token opens /metrics' );

    is( _secret( $file, 'rotate', 'metrics' )->{status}, 0, 'rotated' );
    my $new = _assigned($file)->{GPFORUM_METRICS_TOKEN};
    ok( _scraped( $config, $new ), 'the new token opens it, with no restart' );
    ok( _scraped( $config, $FIRST ), 'and the one before still does' );

    is( _secret( $file, 'rotate', 'metrics', '--finish' )->{status},
        0, 'finished' );
    ok( _scraped( $config,  $new ), 'the new token still opens it' );
    ok( !_scraped( $config, $FIRST ),
        'and the one before is refused, with no restart' );
    is_deeply( $config->accepted_metrics_tokens,
        [$FIRST], 'the configuration itself is as the service started' );
    like( join( "\n", map { $_->[1] } @{ $watched->{logged} } ),
        qr/\Q$file\E/msx, 'the log names the file the tokens were read from' );
    unlike( join( "\n", map { $_->[1] } @{ $watched->{logged} } ),
        qr/\Q$new\E|\Q$FIRST\E/msx, 'and never a token' );

    return;
}

sub _application_follows_its_file {
    my $file = _file( 'application.env', $FIRST );
    local $ENV{GPFORUM_ENV_FILE}      = $file;
    local $ENV{GPFORUM_METRICS_TOKEN} = $FIRST;
    my $test = Test::Mojo->new('GPForum');
    $test->app->helper(
        gp_metrics_snapshot => sub { GPForum::Test::MetricsSnapshot->new } );
    $test->app->helper(
        gp_readiness => sub { GPForum::Test::ReadyHealth->new } );
    my $scrape = sub ($token) {
        return $test->get_ok(
            '/metrics' => { 'X-GPForum-Metrics-Token' => $token } )
          ->tx->res->code;
    };

    is( $scrape->($FIRST), $HTTP_OK,
        '/metrics takes the token it started with' );
    _secret( $file, 'rotate', 'metrics' );
    my $new = _assigned($file)->{GPFORUM_METRICS_TOKEN};
    is( $scrape->($new),   $HTTP_OK, 'the new one, with no restart' );
    is( $scrape->($FIRST), $HTTP_OK, 'and the one before' );
    $test->get_ok( '/health/ready' => { Authorization => "Bearer $new" } )
      ->json_is(
        '/checks/0/name' => 'database',
        'the full readiness report takes the new one too'
      );

    _secret( $file, 'rotate', 'metrics', '--finish' );
    is( $scrape->($FIRST), $HTTP_UNAUTHORIZED,
        'finished, the one before is refused' );
    is( $scrape->($new), $HTTP_OK, 'and the new one stays' );

    return;
}

sub _unchanged_file_not_read {
    my $file   = _file( 'quiet.env', $FIRST );
    my $parser = GPForum::Test::CountingParser->new;
    my $config = _config($FIRST);
    my $tokens = GPForum::Service::Operations::MetricsTokens->watch(
        $config,
        parser      => $parser,
        environment => { GPFORUM_ENV_FILE => "$file" },
    );
    my $read = $parser->lines;
    ok( $read, 'the file is read once at start' );
    for ( 1 .. $CHECKS ) { $tokens->accepted_metrics_tokens }
    is( $parser->lines, $read, 'ten checks later, one stat each, no read' );

    _write( $file, _line( 'GPFORUM_METRICS_TOKEN', 'b' x $TOKEN_LENGTH ) );
    $tokens->accepted_metrics_tokens;
    cmp_ok( $parser->lines, q{>}, $read, 'a changed file is read again' );

    return;
}

sub _never_none {
    my $file    = _file( 'kept.env', $FIRST );
    my $watched = _watch($file);
    my $config  = $watched->{config};
    my $tokens  = $watched->{tokens};

    _write( $file, "GPFORUM_ENV=production\n" );
    ok(
        !$access->request_authorized( Mojo::Headers->new, $config ),
        'a file without a token does not open /metrics'
    );
    ok( _scraped( $config, $FIRST ), 'and the token before still works' );
    for ( 1 .. $CHECKS ) { $tokens->accepted_metrics_tokens }
    is( _warnings( $watched, qr/names [ ] no [ ] GPFORUM_METRICS_TOKEN/msx ),
        1, 'said once, however many checks follow' );

    _write( $file, _line( 'GPFORUM_METRICS_TOKEN', q{} ) );
    ok( !$access->request_authorized( Mojo::Headers->new, $config ),
        'nor does an empty one' );

    _write( $file,
        _line( 'GPFORUM_METRICS_TOKEN', $OTHER_FORUM )
          . "this is not an assignment\n" );
    ok( _scraped( $config,  $FIRST ), 'a line it cannot read keeps them' );
    ok( !_scraped( $config, $OTHER_FORUM ), 'and nothing else is read' );
    is( _warnings( $watched, qr/line [ ] 2/msx ), 1, 'naming the line' );

    _write( $file, _line( 'GPFORUM_METRICS_TOKEN', $OTHER_FORUM ) );
    chmod $GROUP_WRITABLE, "$file" or croak "chmod: $ERRNO";
    ok( !_scraped( $config, $OTHER_FORUM ),
        'a file another account may write is not read' );
    is( _warnings( $watched, qr/chmod [ ] 0640/msx ), 1, 'with its chmod' );

    chmod $SECRET_FILE_MODE, "$file" or croak "chmod: $ERRNO";
    ok( _scraped( $config, $OTHER_FORUM ), 'closed again, it is read' );

    unlink "$file" or croak "unlink: $ERRNO";
    ok( _scraped( $config, $OTHER_FORUM ), 'a file gone keeps them too' );
    ok( !$access->request_authorized( Mojo::Headers->new, $config ),
        'and /metrics stays closed' );

    return;
}

sub _other_tokens_not_followed {
    my $file    = _file( 'other.env', $OTHER_FORUM );
    my $watched = _watch( $file, $FIRST );
    ok( !$watched->{tokens}->following,
        q{another forum's file, or a shell's override, is not followed} );
    is( _warnings( $watched, qr/restarts/msx ), 1, 'the start says so' );

    _write( $file, _line( 'GPFORUM_METRICS_TOKEN', $OTHER_FORUM ) );
    ok( !_scraped( $watched->{config}, $OTHER_FORUM ),
        'its tokens never open /metrics' );
    ok(
        _scraped( $watched->{config}, $FIRST ),
        'the service keeps the ones it started with'
    );

    return;
}

sub _unwatched_keeps_its_list {
    my $config = _config($FIRST);
    is( GPForum::Service::Operations::MetricsTokens->for_config($config),
        $config, 'the configuration answers for itself' );
    my $open = GPForum::Config->new;
    ok(
        $access->request_authorized( Mojo::Headers->new, $open ),
        'development without a token stays open, as before'
    );

    return;
}

sub _declared_file {
    my $file = _file( 'declared.env', $FIRST );
    GPForum::Command::Support::ServiceEnvironment->new(
        file        => _file( 'loaded.env', $OTHER_FORUM ),
        environment => {},
    )->load;
    my $tokens = GPForum::Service::Operations::MetricsTokens->watch(
        _config($FIRST),
        parser      => 'GPForum::Command::Support::ServiceEnvironment',
        environment => { GPFORUM_ENV_FILE => "$file" },
    );
    is( $tokens->file, "$file", 'the declared file, before the one loaded' );
    ok( $tokens->following, 'and followed' );

    return;
}

sub _session_secret_not_read {
    my $file = _file( 'session.env', $FIRST );
    path($file)
      ->spew( path($file)->slurp
          . _line( 'GPFORUM_SESSION_SECRET', 's' x $TOKEN_LENGTH ) );
    my $watched = _watch($file);
    my $config  = $watched->{config};
    my $signing = $config->signing_secrets;
    _secret( $file, 'rotate', 'session' );
    $watched->{tokens}->accepted_metrics_tokens;
    is_deeply( $config->signing_secrets, $signing,
        'cookies are signed with the secrets the service started with' );

    return;
}

sub _scrapes_during_rotations {
    my $file    = _file( 'busy.env', $FIRST );
    my $watched = _watch($file);
    my $config  = $watched->{config};

    my $child = fork // croak "fork: $ERRNO";
    if ( !$child ) {
        my $status = 0;
        for ( 1 .. $ROTATIONS ) {
            $status ||= _secret( $file, 'rotate', 'metrics' )->{status};
            sleep $PAUSE;
        }
        _exit( $status ? $CHILD_FAILED : 0 );
    }

    my ( $scrapes, $refused, $opened, $torn ) = ( 0, 0, 0, 0 );
    my $deadline = time + $LONGEST_WAIT_SECS;
    while ( time < $deadline ) {
        my $done = waitpid( $child, POSIX::WNOHANG() ) == $child;
        $scrapes++;
        $refused += _scraped( $config, $FIRST ) ? 0 : 1;
        $opened +=
          $access->request_authorized( Mojo::Headers->new, $config ) ? 1 : 0;
        my $tokens = $watched->{tokens}->accepted_metrics_tokens;
        $torn += $tokens->[-1] eq $FIRST && length $tokens->[0] ? 0 : 1;
        if ($done) {
            is( $CHILD_ERROR >> $EXIT_SHIFT, 0, 'every rotation was written' );
            last;
        }
    }
    cmp_ok( $scrapes, q{>=}, 1, "$scrapes scrapes while it rotated" );
    is( $refused, 0, 'the first token, still listed, was never refused' );
    is( $opened,  0, 'a scrape without a token never got in' );
    is( $torn,    0, 'each list read was a whole one' );

    my $tokens = $watched->{tokens}->accepted_metrics_tokens;
    is( scalar @{$tokens}, $ROTATIONS + 1, 'and the last has every token' );
    is(
        $tokens->[0],
        _assigned($file)->{GPFORUM_METRICS_TOKEN},
        'the newest first'
    );

    _secret( $file, 'rotate', 'metrics', '--finish' );
    ok( !_scraped( $config, $FIRST ), 'finished, the first is refused' );

    return;
}

sub _written_in_place {
    my $file    = _file( 'edited.env', $FIRST );
    my $watched = _watch($file);
    my $config  = $watched->{config};
    my $text    = path($file)->slurp;

    my $child = fork // croak "fork: $ERRNO";
    if ( !$child ) {
        for ( 1 .. $IN_PLACE_WRITES ) {
            open my $handle, '+<', "$file" or _exit($CHILD_FAILED);
            truncate $handle, 0 or _exit($CHILD_FAILED);
            my $half = int( length($text) / 2 );
            print {$handle} substr $text, 0, $half or _exit($CHILD_FAILED);
            $handle->flush;
            sleep $PAUSE;
            print {$handle} substr $text, $half or _exit($CHILD_FAILED);
            close $handle or _exit($CHILD_FAILED);
            sleep $PAUSE;
        }
        _exit(0);
    }

    my ( $scrapes, $opened ) = ( 0, 0 );
    my $deadline = time + $LONGEST_WAIT_SECS;
    while ( time < $deadline ) {
        my $done = waitpid( $child, POSIX::WNOHANG() ) == $child;
        $scrapes++;
        $opened +=
          $access->request_authorized( Mojo::Headers->new, $config ) ? 1 : 0;
        last if $done;
    }
    is( $opened, 0, "none of $scrapes scrapes without a token got in" );
    ok( _scraped( $config, $FIRST ), 'and the token works once written' );

    return;
}

# An environment file as setup writes it, 0640, with a metrics token.
sub _file ( $name, $token ) {
    my $file = path( $directory, $name );
    _write( $file,
        "GPFORUM_ENV=production\n" . _line( 'GPFORUM_METRICS_TOKEN', $token ) );

    return "$file";
}

# Replaced in one rename, as gpforum secret rotate writes it.
sub _write ( $file, $text ) {
    my $next = "$file.next";
    path($next)->spew($text);
    chmod $SECRET_FILE_MODE, $next or croak "chmod: $ERRNO";
    rename $next, "$file" or croak "rename: $ERRNO";

    return;
}

sub _line ( $name, $value ) {
    return "$name=$value\n";
}

sub _config ( $token, @previous ) {
    return GPForum::Config->new(
        metrics_token           => $token,
        previous_metrics_tokens => [@previous],
    );
}

# The service started on a file: its configuration from the same tokens,
# and the tokens watched as Bootstrap::Operations watches them.
sub _watch ( $file, $token = undef ) {
    my $config = _config( $token // _assigned($file)->{GPFORUM_METRICS_TOKEN} );
    my @logged;
    my $log = Mojo::Log->new;
    $log->unsubscribe('message')->on(
        message => sub ( $, $level, @lines ) {
            push @logged, [ $level, join q{ }, @lines ];
        }
    );
    my $tokens = GPForum::Service::Operations::MetricsTokens->watch(
        $config,
        parser      => 'GPForum::Command::Support::ServiceEnvironment',
        log         => $log,
        environment => { GPFORUM_ENV_FILE => $file },
    );

    return { config => $config, logged => \@logged, tokens => $tokens };
}

sub _warnings ( $watched, $pattern ) {
    return
      scalar grep { $_->[0] eq 'warn' && $_->[1] =~ $pattern }
      @{ $watched->{logged} };
}

sub _scraped ( $config, $token ) {
    return $access->request_authorized(
        Mojo::Headers->new->header( 'X-GPForum-Metrics-Token' => $token ),
        $config );
}

sub _assigned ($file) {
    my %assigned;
    for my $line ( split /^/msx, path($file)->slurp ) {
        my $assignment =
          GPForum::Command::Support::ServiceEnvironment->parse_line($line);
        next if !ref $assignment;
        $assigned{ $assignment->[0] } = $assignment->[1];
    }

    return \%assigned;
}

sub _secret ( $file, @arguments ) {
    my $command = GPForum::Command::Secret->new(
        file               => $file,
        services_installed => 1,
        metrics_reread     => 1,
    );
    my $output = q{};
    my $status;
    {
        open my $stdout, '>', \$output or croak 'capture stdout';
        local *STDOUT = $stdout;
        $status = $command->run(@arguments);
        close $stdout or croak 'close stdout';
    }

    return { output => $output, status => $status };
}

1;
