# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::ServiceUnits;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Find qw(find);
use IPC::Open3 qw(open3);
use List::Util qw(any first max);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);
use Mojo::Util qw(decode);
use Symbol     qw(gensym);

use GPForum::Service::Operations::DeployContract qw(
  deploy_match_text
  deploy_unit_checks
);
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceFiles;

our $VERSION = '0.001';

# The timers, how often each fires, and the service each starts. A timer is
# late when it last fired more than twice its period ago.
const my $HOUR  => 3600;
const my $DAY   => 86_400;
const my $TWICE => 2;
const my @TIMERS => (
    {
        timer   => 'gpforum-scheduled-jobs.timer',
        service => 'gpforum-scheduled-jobs.service',
        period  => $HOUR,
    },
    {
        timer   => 'gpforum-partition-maintenance.timer',
        service => 'gpforum-partition-maintenance.service',
        period  => $DAY,
    },
);

# The services that run all the time, and must run the code on disk.
const my @RUNNING => qw(gpforum.service gpforum-outbox.service);

# What the code is: the files whose change a restart must pick up.
const my @CODE => qw(lib bin migrations);

const my $SECONDS_PER_MINUTE => 60;
const my $MINUTES_PER_HOUR   => 60;
const my $HOURS_PER_DAY      => 24;
const my $EXIT_SHIFT         => 8;
const my $STAT_MTIME         => 9;

has host => sub { return GPForum::Service::Operations::Host->new; };

# The checkout whose deploy/ files the installed ones are compared with.
has root => sub {
    return path(__FILE__)
      ->realpath->dirname->dirname->dirname->dirname->dirname->to_string;
};

# The service files this release ships, written for this host: what an
# installed one is compared with, and how it is put in place again.
has files => sub ($self) {
    return GPForum::Service::Operations::ServiceFiles->new(
        host             => $self->host,
        root             => $self->root,
        environment_file => $self->host->environment_file,
    );
};

# Where this host's service manager reads its files; a test gives its own.
has directory => sub ($self) {
    my $manager = $self->_manager;
    return undef if !defined $manager;

    return $self->files->files($manager)->[0]{destination};
};

# Runs systemctl with the arguments given and returns { exit, output }, or
# undef where there is no systemctl; a test gives its own.
has systemctl => sub {
    my $binary = first { -x }
      map { path( $_, 'systemctl' )->to_string } split /:/msx,
      $ENV{PATH} // q{};
    return undef if !defined $binary;

    return sub (@arguments) { return _capture( $binary, @arguments ) };
};

has now => sub { return time };

# When the code last changed: the newest file under lib/, bin/ and
# migrations/.
has code_changed => sub ($self) {
    my $newest = 0;
    my @roots  = grep { -d } map { path( $self->root, $_ )->to_string } @CODE;
    return 0 if !@roots;

    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if !-f;
                $newest = max( $newest, ( stat _ )[$STAT_MTIME] // 0 );
            },
        },
        @roots
    );

    return $newest;
};

# Whether this host has a service manager GPForum ships files for.
sub applies ($self) {
    return defined $self->_manager && defined $self->directory ? 1 : 0;
}

# The installed files, against the ones this release ships, written for
# this host as gpforum service print writes them, or copied from deploy/
# as they were before it: those not installed, those that miss what the
# service needs (a systemd unit without User=gpforum or the environment
# file), and those that differ from the release's -- a unit copied before
# an upgrade that changed it.
sub units ( $self, $findings ) {
    my $manager = $self->_manager;
    return $findings if !defined $manager;

    my $directory = $self->directory;
    my ( @installed, @missing, @drifted, $broken );
    for my $unit ( grep { !$_->{unwatched} }
        @{ $self->files->files( $manager, $directory ) } )
    {
        my $file = path( $unit->{path} );
        if ( !-e $file ) {
            push @missing, $unit;
            next;
        }
        push @installed, $unit->{name};

        my $bytes = $file->slurp;
        my $text  = decode( 'UTF-8', $bytes ) // $bytes;
        next if any { _normalized($text) eq $_ } $self->_shipped($unit);

        if ( my $lacking = $self->_lacking( $unit->{name}, $text ) ) {
            $broken = 1;
            $findings->add(
                name    => 'units',
                status  => 'fail',
                message => [
                    'doctor.unit_contract',
                    { unit => $file->to_string, labels => $lacking }
                ],
                fixes => $self->_put( [$unit] ),
            );
            next;
        }
        push @drifted, $unit;
    }

    if (@missing) {
        $self->_missing( $findings, \@missing );
    }
    if (@drifted) {
        $self->_drifted( $findings, \@drifted );
    }
    if ( @installed && !@missing && !@drifted && !$broken ) {
        $findings->add(
            name    => 'units',
            status  => 'ok',
            message => [
                'doctor.units_ok',
                { count => scalar @installed, directory => $directory }
            ],
        );
    }

    return $findings;
}

# Units not installed, as one finding with the commands that print them
# for this host, put them in place and start what they run.
sub _missing ( $self, $findings, $missing ) {
    my @missing = @{$missing};
    $findings->add(
        name    => 'units',
        status  => 'degraded',
        message => [
            'doctor.units_missing',
            {
                units     => join( q{, }, map { $_->{name} } @missing ),
                directory => $self->directory,
            }
        ],
        fixes => $self->_put( \@missing, start => 1 ),
    );

    return;
}

# Units that differ from the release's, as one finding with the diff that
# shows how, the commands that put this release's in place, and the
# restart that reads them.
sub _drifted ( $self, $findings, $drifted ) {
    my @drifted = @{$drifted};
    my $manager = $self->_manager;
    my $first   = $drifted[0];
    my @names   = map { $_->{name} } @drifted;
    $findings->add(
        name    => 'units',
        status  => 'degraded',
        message => [
            @drifted == 1
            ? 'doctor.units_drifted_one'
            : 'doctor.units_drifted',
            { units => join q{, }, @names }
        ],
        notes => [
            [
                'doctor.units_diff',
                {
                    command =>
                      $self->files->print_command( $manager, $first->{name} )
                      . " | diff -u $first->{path} -"
                }
            ]
        ],
        fixes => [
            @{ $self->_put( \@drifted ) },
            map { $self->host->reload_command($_) // () }
              @{ $self->files->restarted( $manager, @names ) },
        ],
    );

    return;
}

# When each timer last fired, and whether the run it started succeeded.
# systemd only: rc and launchd keep no such record.
sub timers ( $self, $findings ) {
    return $findings if !$self->_systemd;

    for my $timer (@TIMERS) {
        my $shown = $self->_show( $timer->{timer},
            qw(LoadState UnitFileState ActiveState LastTriggerUSec) );
        next if !$shown || _not_installed($shown);
        my $name = $timer->{timer};

        if ( ( $shown->{ActiveState} // q{} ) ne 'active' ) {
            $findings->add(
                name    => 'timers',
                status  => 'degraded',
                message => [ 'doctor.timer_off', { timer => $name } ],
                fixes   => [ $self->host->start_command($name) // () ],
            );
            next;
        }

        my ($fired) = ( $shown->{LastTriggerUSec} // q{} ) =~ /\A @ (\d+)/msx;
        if ( !defined $fired ) {
            $findings->add(
                name    => 'timers',
                status  => 'ok',
                message => [ 'doctor.timer_waiting', { timer => $name } ],
            );
            next;
        }

        my $age    = $self->now - $fired;
        my $result = $self->_show( $timer->{service}, 'Result' ) // {};
        if ( ( $result->{Result} // 'success' ) ne 'success' ) {
            $findings->add(
                name    => 'timers',
                status  => 'degraded',
                message => [
                    'doctor.timer_failed',
                    { timer => $name, age => $self->age($age) }
                ],
                fixes => [
                    "journalctl -u $timer->{service} -n 50",
                    "sudo systemctl start $timer->{service}",
                ],
            );
            next;
        }

        my $late = $age > $TWICE * $timer->{period};
        $findings->add(
            name    => 'timers',
            status  => $late ? 'degraded' : 'ok',
            message => [
                $late ? 'doctor.timer_late' : 'doctor.timer_ok',
                { timer => $name, age => $self->age($age) }
            ],
            fixes => $late ? ["systemctl status $name"] : [],
        );
    }

    return $findings;
}

# Whether the web service and the outbox worker run, and run the code on
# disk: one started before the code changed still serves the release
# before it. systemd only.
sub running ( $self, $findings ) {
    return $findings if !$self->_systemd;

    my $changed = $self->code_changed;
    my ( @stale, $any );
    for my $service (@RUNNING) {
        my $shown = $self->_show( $service,
            qw(LoadState ActiveState ActiveEnterTimestamp) );
        next if !$shown || _not_installed($shown);
        $any = 1;

        my $bare = $service =~ s/[.]service\z//rmsx;
        if ( ( $shown->{ActiveState} // q{} ) ne 'active' ) {
            $findings->add(
                name    => 'services',
                status  => 'fail',
                message => [ 'doctor.service_stopped', { service => $bare } ],
                fixes   => [
                    $self->host->start_command($bare) // (),
                    "journalctl -u $bare -n 50",
                ],
            );
            next;
        }
        my ($started) =
          ( $shown->{ActiveEnterTimestamp} // q{} ) =~ /\A @ (\d+)/msx;
        if ( defined $started && $started < $changed ) {
            push @stale,
              {
                service => $bare,
                started => $self->age( $self->now - $started ),
                changed => $self->age( $self->now - $changed ),
              };
        }
    }

    if (@stale) {
        $findings->add(
            name    => 'services',
            status  => 'degraded',
            message => [ 'doctor.service_stale', $stale[0] ],
            notes   =>
              [ map { [ 'doctor.service_stale', $_ ] } @stale[ 1 .. $#stale ] ],
            fixes => [ $self->_restart( map { $_->{service} } @stale ) // () ],
        );
    }
    elsif ( $any
        && !any { $_->{name} eq 'services' } @{ $findings->items } )
    {
        $findings->add(
            name    => 'services',
            status  => 'ok',
            message => ['doctor.services_current'],
        );
    }

    return $findings;
}

# A span of seconds as the operator reads it: seconds, minutes, hours or
# days, in their language.
sub age ( $self, $seconds ) {
    my $catalog = $self->host->catalog;
    $seconds = max( 0, int $seconds );
    return $catalog->text( 'doctor.seconds', { count => $seconds } )
      if $seconds < $SECONDS_PER_MINUTE;

    my $minutes = int( $seconds / $SECONDS_PER_MINUTE );
    return $catalog->text( 'doctor.minutes', { count => $minutes } )
      if $minutes < $MINUTES_PER_HOUR;

    my $hours = int( $minutes / $MINUTES_PER_HOUR );
    return $catalog->text( 'doctor.hours', { count => $hours } )
      if $hours < $HOURS_PER_DAY;

    my $days = int( $hours / $HOURS_PER_DAY );
    return $catalog->text('doctor.day') if $days == 1;

    return $catalog->text( 'doctor.days', { count => $days } );
}

# A unit systemd has no file for, which units() reports as not installed.
sub _not_installed ($shown) {
    return ( $shown->{LoadState} // q{} ) eq 'not-found' ? 1 : 0;
}

# The service manager this host runs GPForum under, or undef.
sub _manager ($self) {
    return $self->host->service_manager;
}

# The command that restarts the services named, under this host's manager.
sub _restart ( $self, @services ) {
    return 'sudo systemctl restart ' . join q{ }, @services
      if ( $self->host->service_manager // q{} ) eq 'systemd';

    my @commands = map { $self->host->restart_command($_) // () } @services;
    return @commands ? join( q{ && }, @commands ) : undef;
}

sub _systemd ($self) {
    return ( $self->host->service_manager // q{} ) eq 'systemd'
      && defined $self->systemctl ? 1 : 0;
}

# What a systemd unit lacks of the contract the deploy files keep
# (DeployContract), as a list of labels; undef when nothing, or for a file
# without a contract.
sub _lacking ( $self, $name, $text ) {
    my $expected = first { $_->{name} eq $name } deploy_unit_checks();
    return undef if !$expected || $self->host->service_manager ne 'systemd';

    my $match =
      deploy_match_text( $text, $self->_reading_this_host_file($expected) );
    return undef if !@{ $match->{missing_labels} };

    return join q{, }, @{ $match->{missing_labels} };
}

# The contract, with the environment file a unit reads either the one the
# contract names or the one this host's settings were read from: a unit
# gpforum --env-file FILE service print wrote names FILE, which it reads,
# not lacks.
sub _reading_this_host_file ( $self, $expected ) {
    my $file   = $self->files->env_file('systemd');
    my @labels = @{ $expected->{labels} };
    my @must   = @{ $expected->{must_match} };
    for my $index ( grep { $labels[$_] eq 'EnvironmentFile' } 0 .. $#labels ) {
        my $named = $must[$index];
        $must[$index] = qr/(?:$named)|(?:^EnvironmentFile=\Q$file\E[ \t]*$)/msx;
    }

    return { %{$expected}, must_match => \@must };
}

# What an installed file may be, normalized: each template it may be a copy
# of, written for this host, or as deploy/ has it, which an install before
# gpforum service print copied.
sub _shipped ( $self, $unit ) {
    my $manager = $self->_manager;
    my @templates =
      grep { defined && -e path( $self->root, $_ ) }
      ( $unit->{template}, $unit->{socket} );

    my @rendered =
      map { $self->files->render_template( $manager, $_, $unit ) } @templates;
    my @shipped = map { path( $self->root, $_ )->slurp('UTF-8') } @templates;

    return map { _normalized($_) } @rendered, @shipped;
}

# Trailing blanks and line endings do not make a unit differ.
sub _normalized ($text) {
    $text =~ s/[ \t]+$//gmsx;
    $text =~ s/\r\n/\n/gmsx;
    $text =~ s/\s+\z/\n/msx;

    return $text;
}

# The commands that print the units for this host and put them in place,
# and with start, start what they run.
sub _put ( $self, $units, %options ) {
    return $self->files->steps(
        $self->_manager,
        names     => [ map { $_->{name} } @{$units} ],
        directory => $self->directory,
        %options,
    );
}

# systemctl show's properties of a unit, as a hash, with timestamps as
# @epoch; undef when systemctl could not be asked.
sub _show ( $self, $unit, @properties ) {
    my $result = $self->systemctl->(
        'show',                                 '--timestamp=unix',
        map( { "--property=$_" } @properties ), $unit
    );
    return undef if !$result || $result->{exit};

    my %shown;
    for my $line ( split /\n/msx, $result->{output} // q{} ) {
        my ( $name, $value ) = $line =~ /\A ([^=]+) = (.*) \z/msx;
        next if !defined $name;
        $shown{$name} = $value;
    }

    return \%shown;
}

sub _capture ( $binary, @arguments ) {
    my $errors = gensym;
    my $pid    = open3( my $input, my $output, $errors, $binary, @arguments );
    close $input or croak "cannot close systemctl's input: $OS_ERROR";
    my $text = do { local $INPUT_RECORD_SEPARATOR = undef; <$output> }
      // q{};
    my $said = do { local $INPUT_RECORD_SEPARATOR = undef; <$errors> }
      // q{};
    waitpid $pid, 0;

    return {
        exit   => $CHILD_ERROR >> $EXIT_SHIFT,
        output => $text,
        errors => $said,
    };
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::ServiceUnits - The service files installed on
this host, its timers and its running services, against this release.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $units    = GPForum::Service::Operations::ServiceUnits->new;
    my $findings = GPForum::Service::Operations::Findings->new;
    $units->units($findings);      # installed, as shipped?
    $units->timers($findings);     # each timer's last run
    $units->running($findings);    # running the code on disk?

=head1 DESCRIPTION

C<gpforum doctor>'s look at how the host runs GPForum. It compares the
systemd units, rc.d scripts or launchd property lists installed with those
in this checkout's F<deploy/>: one missing, one that lacks what the service
needs (L<GPForum::Service::Operations::DeployContract>), and one that differs
from the release's -- a unit copied before an upgrade changed it -- each
with the commands that copy it again. Under systemd it also reads when each
timer last fired and whether its run succeeded, and whether the web service
and the outbox worker run and were started after the code last changed.

=head1 SUBROUTINES/METHODS

=head2 host

The L<GPForum::Service::Operations::Host> the commands are written for.

=head2 root

The checkout whose F<deploy/> files are compared with.

=head2 directory

Where this host's service manager reads its files.

=head2 systemctl

A code reference that runs systemctl and returns C<exit> and C<output>, or
undef where there is no systemctl.

=head2 now

The time, in epoch seconds.

=head2 code_changed

When the newest file under F<lib/>, F<bin/> and F<migrations/> changed.

=head2 applies

Whether the host has a service manager GPForum ships files for.

=head2 units

Adds the installed files' findings to the findings given and returns them.

=head2 timers

Adds each timer's finding (systemd only) and returns the findings.

=head2 running

Adds whether the web service and the outbox worker run the code on disk
(systemd only) and returns the findings.

=head2 age

A number of seconds as the operator reads it, in their language.

=head1 DIAGNOSTICS

None: what cannot be read is left out.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<PATH> to find systemctl.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::DeployContract>,
L<GPForum::Service::Operations::Findings>,
L<GPForum::Service::Operations::Host>, L<IPC::Open3>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The timers and the running services are read from systemd only. Under rc.d
and launchd the files are compared, and the rest is left to C<service
status> and C<launchctl print>. C<systemctl show --timestamp=unix> needs
systemd 251 or later; an older one gives no times, and the timers then read
as not yet fired.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
