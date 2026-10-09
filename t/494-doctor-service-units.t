# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceUnits;

our $VERSION = '0.001';

# What gpforum doctor reads of how a host runs GPForum: the service files
# installed against this release's deploy/, systemd's timers, and whether
# the web service and the outbox worker run the code on disk. Two of the
# audit's ten breakages are here -- a timer disabled, a unit drifted -- and
# the stale service an upgrade leaves without a restart. systemctl is a
# double that answers what systemctl show would.

const my $NOW            => 1_800_000_000;
const my $HOUR           => 3_600;
const my $THREE_DAYS     => 3 * 86_400;
const my $TWELVE_MINUTES => 12 * 60;
const my $ROOT           => path(q{.})->to_abs->to_string;

subtest 'units installed as shipped read as one line' => sub {
    my $units = _units( _installed() );
    my $found = $units->units( _findings() );
    is( $found->status, 'ok', 'nothing to fix' );
    my $directory = $units->directory;
    _has(
        $found->human_text,
        "services: 6 files in $directory, as this release ships them",
        'counted, with the directory'
    );
};

subtest 'a missing unit names the copy that installs it' => sub {
    my $directory = _installed();
    unlink "$directory/gpforum-outbox.service";
    my $text = _units($directory)->units( _findings() )->human_text;
    _has(
        $text,
        '! services: gpforum-outbox.service not installed',
        'the unit is named'
    );
    _has(
        $text,
        'sudo gpforum service print systemd gpforum-outbox.service'
          . " --to $directory\n",
        'with the copy, printed for this host'
    );
    _has( $text, q{sudo systemctl daemon-reload}, 'and the reload' );
    _has(
        $text,
        q{sudo systemctl enable --now gpforum-outbox},
        'and the start of what it runs'
    );
};

subtest 'a unit that drifted from the release says how, and copies it again' =>
  sub {
    my $directory = _installed();
    my $unit      = path( $directory, 'gpforum.service' );
    $unit->spew( $unit->slurp =~ s/^LimitNOFILE=.*$/LimitNOFILE=1024/rmsx );
    my $text = _units($directory)->units( _findings() )->human_text;
    _has(
        $text,
        q{gpforum.service differs from this release's},
        'the drift is named'
    );
    _has(
        $text,
        'gpforum service print systemd gpforum.service | diff -u'
          . " $directory/gpforum.service - shows how",
        'with the diff that shows it, against the one printed for this host'
    );
    _has(
        $text,
        "sudo systemctl restart gpforum\n",
        'and the restart of the service it runs'
    );

    $unit->spew( $unit->slurp =~ s/^EnvironmentFile=.*\n//rmsx );
    my $broken = _units($directory)->units( _findings() );
    is( $broken->status, 'fail', 'one without the environment file fails' );
    _has(
        $broken->human_text,
        q{lacks EnvironmentFile},
        'naming what it lacks'
    );
  };

subtest 'timers: on, recent and successful, or what to do' => sub {
    my $shown = {
        'gpforum-scheduled-jobs.timer' => {
            LoadState       => 'loaded',
            ActiveState     => 'inactive',
            UnitFileState   => 'disabled',
            LastTriggerUSec => q{},
        },
        'gpforum-partition-maintenance.timer' => {
            LoadState       => 'loaded',
            ActiveState     => 'active',
            UnitFileState   => 'enabled',
            LastTriggerUSec => q{@} . ( $NOW - $THREE_DAYS ),
        },
        'gpforum-partition-maintenance.service' => { Result => 'success' },
    };
    my $text =
      _units( _installed(), $shown )->timers( _findings() )->human_text;
    _has(
        $text,
        q{timer: gpforum-scheduled-jobs.timer is not on},
        'a disabled timer is named'
    );
    _has(
        $text,
        q{Fix: sudo systemctl enable --now gpforum-scheduled-jobs.timer},
        'with the command that turns it on'
    );
    _has(
        $text,
        q{gpforum-partition-maintenance.timer last fired 3 days ago},
        'a late one says how late'
    );

    my $fresh = {
        'gpforum-scheduled-jobs.timer' => {
            LoadState       => 'loaded',
            ActiveState     => 'active',
            LastTriggerUSec => q{@} . ( $NOW - $TWELVE_MINUTES ),
        },
        'gpforum-scheduled-jobs.service'      => { Result    => 'success' },
        'gpforum-partition-maintenance.timer' => { LoadState => 'not-found' },
    };
    my $ok = _units( _installed(), $fresh )->timers( _findings() );
    is( $ok->status, 'ok', 'a recent run is fine' );
    _has( $ok->human_text, q{fired 12 min ago}, 'and says when' );
    unlike( $ok->human_text, qr/partition-maintenance/msx,
        'a timer not installed is left to the units line' );
};

subtest 'services: running, and on the code on disk' => sub {
    my $stale = {
        'gpforum.service' => {
            LoadState            => 'loaded',
            ActiveState          => 'active',
            ActiveEnterTimestamp => q{@} . ( $NOW - 2 * $HOUR ),
        },
        'gpforum-outbox.service' => {
            LoadState   => 'loaded',
            ActiveState => 'failed',
        },
    };
    my $units = _units( _installed(), $stale );
    $units->code_changed( $NOW - $HOUR );
    my $found = $units->running( _findings() );
    is( $found->status, 'fail', 'a stopped worker fails' );
    my $text = $found->human_text;
    _has(
        $text,
        q{services: gpforum-outbox is not running},
        'the stopped one is named'
    );
    _has(
        $text,
        q{Fix: sudo systemctl enable --now gpforum-outbox},
        'with its start'
    );
    _has(
        $text,
        q{gpforum has run for 2 h, but the code changed 1 h ago},
        'the web service still runs the release before'
    );
    _has(
        $text,
        "sudo systemctl restart gpforum\n",
        'and the restart that ends it'
    );
};

subtest 'in Italian' => sub {
    my $directory = _installed();
    unlink "$directory/gpforum-outbox.service";
    my $text =
      _units( $directory, {}, 'it' )->units( _findings('it') )->human_text;
    _has( $text, q{servizi: gpforum-outbox.service non installati},
        'the line' );
    _has( $text, 'gpforum service print systemd gpforum-outbox.service',
        'and the fix' );
};

done_testing();

sub _has ( $text, $phrase, $name ) {
    ok( index( $text, $phrase ) >= 0, $name ) or diag $text;

    return;
}

# A unit directory holding every systemd file this release ships.
sub _installed {
    my $directory = tempdir( CLEANUP => 1 );
    for my $file ( path('deploy/systemd')->list->each ) {
        next if $file->basename eq 'gpforum-unix-socket.service';
        $file->copy_to( path( $directory, $file->basename ) );
    }

    return $directory;
}

sub _units ( $directory, $shown = {}, $language = 'en' ) {
    return GPForum::Service::Operations::ServiceUnits->new(
        directory => $directory,
        host      => _host($language),
        now       => $NOW,
        root      => $ROOT,
        systemctl => sub (@arguments) {
            my $unit = $arguments[-1];
            my %properties =
              map { /\A --property= (\w+) \z/msx ? ( $1 => 1 ) : () }
              @arguments;
            my $unit_shown = $shown->{$unit} // { LoadState => 'not-found' };
            return {
                exit   => 0,
                output => join q{},
                map { "$_=" . ( $unit_shown->{$_} // q{} ) . "\n" }
                  grep { $properties{$_} } sort keys %{$unit_shown},
            };
        },
    );
}

sub _host ( $language = 'en' ) {
    return GPForum::Service::Operations::Host->new(
        catalog     => _catalog($language),
        environment => 'production',
        os          => GPForum::OS->from_name('linux'),
    );
}

sub _catalog ( $language = 'en' ) {
    return GPForum::Service::I18N::CliCatalog->new( language => $language );
}

sub _findings ( $language = 'en' ) {
    return GPForum::Service::Operations::Findings->new(
        catalog => _catalog($language) );
}

1;
