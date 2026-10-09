# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::Host;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;

our $VERSION = '0.001';

# How this host runs GPForum's services, by operating system, as deploy/
# ships them: systemd units on Linux, rc.d scripts on FreeBSD, launchd
# property lists on macOS. A fix names the command for the host it is read
# on, not a Linux one everywhere.
const my %MANAGER => (
    linux   => 'systemd',
    freebsd => 'rc',
    darwin  => 'launchd',
);
const my %START => (
    systemd => 'sudo systemctl enable --now {service}',
    rc => 'sudo sysrc {rc_name}_enable=YES && sudo service {rc_name} start',
    launchd => 'sudo launchctl bootstrap system'
      . ' /Library/LaunchDaemons/com.gpforum.{short}.plist',
);
const my %RESTART => (
    systemd => 'sudo systemctl restart {service}',
    rc      => 'sudo service {rc_name} restart',
    launchd => 'sudo launchctl kickstart -k system/com.gpforum.{short}',
);

# And how a service reads its service file again once a new one is in
# place: launchd keeps the property list it loaded until the job is booted
# out, and a kickstart restarts it with the old one.
const my %RELOAD => (
    systemd => 'sudo systemctl restart {service}',
    rc      => 'sudo service {rc_name} restart',
    launchd => 'sudo launchctl bootout system/com.gpforum.{short}'
      . ' && sudo launchctl bootstrap system'
      . ' /Library/LaunchDaemons/com.gpforum.{short}.plist',
);

# The deployed environments, where the settings live in the service's
# environment file rather than in an operator's shell.
const my $DEPLOYED => qr/\A (?: staging | production )/msx;

# A word a shell reads as it is: a path with a space or a quote in it is
# quoted, so a command printed with it runs as printed.
const my $SHELL_SAFE => qr{\A [\w/.,:@%+=-]+ \z}msx;

has os          => sub { return GPForum::OS->detect; };
has environment => sub { return $ENV{GPFORUM_ENV} // 'development'; };
has catalog     => sub { return GPForum::Service::I18N::CliCatalog->new; };

sub is_deployed ($self) {
    return $self->environment =~ $DEPLOYED ? 1 : 0;
}

# The environment file the settings were read from, when the caller knows:
# `gpforum --env-file FILE` names another, and on macOS the front door reads
# Homebrew's.
has environment_file => undef;    # optional: the operating system's otherwise

# The file the service reads its settings from on this host.
sub settings_file ($self) {
    return $self->environment_file // $self->os->environment_file;
}

# Where an operator changes a setting, as a phrase that ends a sentence:
# "in /etc/gpforum/gpforum.env" once deployed, "in your shell's environment"
# in development, where nothing reads that file -- unless the front door read
# the settings from a file, which is then where they are, in any
# environment.
sub where ($self) {
    return $self->catalog->text( 'database.where_shell', {} )
      if !$self->is_deployed && !defined $self->environment_file;

    return $self->catalog->text( 'database.where_file',
        { path => $self->settings_file } );
}

# systemd, rc or launchd; undef on an operating system GPForum has no
# service files for.
sub service_manager ($self) {
    my $name = $self->os->name;

    # A constant hash dies on a key it lacks: an operating system GPForum
    # does not know stopped doctor instead of being left out.
    return exists $MANAGER{$name} ? $MANAGER{$name} : undef;
}

# The command that enables and starts one of GPForum's services, named as
# systemd names it (gpforum-outbox, gpforum-scheduled-jobs.timer), or undef
# where GPForum ships no service files.
sub start_command ( $self, $service ) {
    return $self->_service_command( \%START, $service );
}

sub restart_command ( $self, $service ) {
    return $self->_service_command( \%RESTART, $service );
}

# The command that restarts a service on a new copy of its service file.
sub reload_command ( $self, $service ) {
    return $self->_service_command( \%RELOAD, $service );
}

# The commands that enable and start several of GPForum's services, named as
# systemd names them: one line under systemd, whose systemctl takes them
# all, and under launchd, whose bootstrap takes every property list
# (launchctl(1)); one a service under rc. None where GPForum ships no
# service files.
sub start_all ( $self, @services ) {
    my $manager = $self->service_manager;
    return () if !@services || !defined $manager;
    return $self->start_command( join q{ }, @services )
      if $manager eq 'systemd';
    if ( $manager eq 'launchd' ) {
        my @commands = map { $self->start_command($_) } @services;
        my ($first) = shift @commands;
        return join q{ }, $first,
          map { s/\A sudo [ ] launchctl [ ] bootstrap [ ] system [ ]//rmsx }
          @commands;
    }

    return map { $self->start_command($_) } @services;
}

# How to install what an operating-system package provides: with sudo, but
# not under Homebrew, which refuses to run as root.
sub install_command ( $self, $packages ) {
    return $self->_privileged($packages);
}

# The antivirus's install command for this host, from the operating
# system's packaging, or undef where none is known.
sub antivirus_install ($self) {
    my $install = $self->os->antivirus_packaging->{install};
    return undef if !defined $install;

    return $self->_privileged($install);
}

# The command that enables and starts an operating-system package's service
# (clamd, freshclam): systemd's or rc.d's, or Homebrew's on macOS. Takes the
# packaging GPForum::OS describes, whose first service is the one started.
sub package_start_command ( $self, $packaging ) {
    my $manager = $self->service_manager // q{};
    my $service = $packaging->{services}[0];
    return "brew services start $packaging->{packages}[0]"
      if $manager eq 'launchd';
    return "sudo sysrc ${service}_enable=YES && sudo service $service start"
      if $manager eq 'rc';

    return "sudo systemctl enable --now $service";
}

# A word -- a path, a name -- as a command printed for an operator types
# it: as it is when a shell reads it so, else in single quotes.
sub shell_word ( $, $word ) {
    return $word if $word =~ $SHELL_SAFE;

    return q{'} . ( $word =~ s/'/'\\''/grmsx ) . q{'};
}

sub _privileged ( $self, $command ) {
    return $command if $command =~ /\A sudo \s/msx;
    return $command if $self->os->name eq 'darwin';

    return "sudo $command";
}

sub _service_command ( $self, $templates, $service ) {
    my $manager = $self->service_manager;
    return undef if !defined $manager;

    my $bare  = $service =~ s/\A gpforum- | [.] (?: service | timer ) \z//grmsx;
    my $short = $bare eq 'gpforum' ? 'app' : $bare;
    my $rc_name = $service =~ s/[.] (?: service | timer ) \z//rmsx =~ tr/-/_/r;
    my %names   = (
        service => $service,
        short   => $short,
        rc_name => $rc_name,
    );

    return $templates->{$manager} =~ s{ [{] (\w+) [}] }{$names{$1}}grmsx;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::Host - Where this host keeps GPForum's
settings and how it runs its services.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $host = GPForum::Service::Operations::Host->new;
    say $host->where;                           # in /etc/gpforum/gpforum.env
    say $host->start_command('gpforum-outbox'); # sudo systemctl enable ...

=head1 DESCRIPTION

What a fix line needs to name the right file and the right command on the
host it is read on: the environment GPForum runs in, the file the service
reads its settings from, and how the operating system starts and restarts
GPForum's services -- systemd on Linux, rc.d on FreeBSD, launchd on macOS,
as C<deploy/> ships them.

=head1 SUBROUTINES/METHODS

=head2 os

The L<GPForum::OS> profile; the detected one by default.

=head2 environment

The C<GPFORUM_ENV> in force; C<development> when unset.

=head2 catalog

The L<GPForum::Service::I18N::CliCatalog> L</where> is written from.

=head2 is_deployed

True in staging and production.

=head2 environment_file

The environment file the settings were read from, when the caller knows it;
undef by default.

=head2 settings_file

L</environment_file>, else the service's environment file on this
operating system.

=head2 where

Where to change a setting, as the end of a sentence: the
L</environment_file> the settings were read from, else the service's
environment file once deployed, else the shell's environment.

=head2 service_manager

C<systemd>, C<rc> or C<launchd>, or undef.

=head2 start_command

Takes a service as systemd names it and returns the command that enables
and starts it on this host, or undef.

=head2 restart_command

Takes a service as systemd names it and returns the command that restarts
it on this host, or undef.

=head2 reload_command

Takes a service as systemd names it and returns the command that restarts
it on a new copy of its service file, or undef: under launchd, a boot out
and a bootstrap, since a kickstart keeps the property list loaded before.

=head2 start_all

Takes services as systemd names them and returns the commands that enable
and start them all on this host: one C<systemctl enable --now> line under
systemd, one command a service under rc and launchd, none elsewhere.

=head2 install_command

Takes a package manager's install command and returns it as an operator
types it: behind C<sudo>, except on macOS, where Homebrew runs as the user.

=head2 shell_word

Takes a word -- a path, a name -- and returns it as a printed command types
it: as it is when a shell reads it so, else in single quotes, so
C</var/backups/my forum> comes back as C<'/var/backups/my forum'>.

=head2 package_start_command

Takes an operating-system packaging description (L<GPForum::OS>
C<antivirus_packaging>) and returns the command that enables and starts its
first service: C<systemctl>, C<sysrc> and C<service>, or C<brew services>.

=head2 antivirus_install

The command that installs clamd on this host, or undef where the operating
system's packaging is not known.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<GPFORUM_ENV> unless an environment is given.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<GPForum::OS>,
L<GPForum::Service::I18N::CliCatalog>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The launchd commands assume the property lists were installed as
LaunchDaemons, as C<deploy/launchd> describes.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
