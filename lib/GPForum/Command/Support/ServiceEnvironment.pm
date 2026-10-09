# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Support::ServiceEnvironment;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);

use GPForum::Command::Support::Verbs;
use GPForum::OS;
use GPForum::X::Config;

our $VERSION = '0.001';

# The service reads its settings from an environment file through its
# supervisor (systemd's EnvironmentFile=, the FreeBSD rc script). A command
# typed by hand saw none of them unless the operator recreated that
# environment -- `sudo -u gpforum sh -c 'set -a; . /etc/gpforum/gpforum.env;
# ...'` -- and without it connected with the development defaults. bin/gpforum
# reads the same file itself, so the front door and the service see the same
# settings (ADR 0120). What the process environment already holds wins:
# systemd has set it from the same file, or the operator set it on purpose.

# How each supervisor GPForum ships units for restarts the web service and its
# outbox worker, which both read the file only when they start.
const my %RESTART => (
    linux   => 'sudo systemctl restart gpforum gpforum-outbox',
    freebsd =>
      'sudo service gpforum restart && sudo service gpforum_outbox restart',
    darwin => 'sudo launchctl kickstart -k system/com.gpforum.app'
      . ' && sudo launchctl kickstart -k system/com.gpforum.outbox',
);

# And how it starts them, the first time or after a stop, as the deployment
# guide does: enabled, so they start again with the host, and on macOS
# loaded into launchd first -- kickstart answers "Could not find service"
# for a plist launchd has not loaded.
const my %START => (
    linux   => 'sudo systemctl enable --now gpforum gpforum-outbox',
    freebsd => 'sudo sysrc gpforum_enable=YES gpforum_outbox_enable=YES'
      . ' && sudo service gpforum start && sudo service gpforum_outbox start',
    darwin => 'sudo launchctl bootstrap system'
      . ' /Library/LaunchDaemons/com.gpforum.app.plist'
      . ' && sudo launchctl bootstrap system'
      . ' /Library/LaunchDaemons/com.gpforum.outbox.plist',
);

# A name as POSIX shells and systemd accept it.
const my $NAME => qr/[[:alpha:]_][[:alnum:]_]*/msx;

# The escapes a double-quoted value may carry, as Config::Report writes them
# and as both systemd and sh read them.
const my %ESCAPED => map { $_ => $_ } ( q{"}, q{\\}, q{$}, q{`} );

# What this process read, for a reader that names it: the configuration
# report's last line, a command that writes the file back. And the names it
# set from the file: any other the environment holds came from the process
# environment, where a fix sets it, not in the file.
my $LOADED;
my @ASSIGNED;

# What a file name needs to be typed bare in a shell; one with anything else
# is single-quoted.
const my $SHELL_SAFE => qr{\A [\w/.,:@%+=-]+ \z}msx;

has os => sub { return GPForum::OS->detect; };

# The file named with --env-file, which must exist; otherwise the host's.
has file => undef;    # optional: the host's default otherwise

# Whether a file this reader cannot open, or a line it cannot parse, stops
# the load. The front door says which file or line; the service, started by
# a supervisor that already read the file its own way (systemd reads it as
# root, before it drops to the service's user), keeps going with what it
# could read.
has strict => 1;

# The environment the file is loaded into.
has environment => sub { return \%ENV; };

sub loaded ($class) {
    return $LOADED;
}

sub assigned ($class) {
    return [@ASSIGNED];
}

# A text whose gpforum commands read the file this process read: one read
# with --env-file that is not the host's own is named in each, so `gpforum
# migrate`, offered after `gpforum --env-file FILE doctor`, does not migrate
# the database the host's file names.
sub as_read ( $class, $text ) {
    return $text if !defined $text || !defined $LOADED;
    return $text if $LOADED eq $class->new->default_file;

    # Each verb ends where a name would: mail-check is not the start of
    # mail-lifecycle-check. The FreeBSD service is named gpforum too, and
    # `sudo service gpforum start` starts it: read as the verb start, it
    # became `service gpforum --env-file FILE start`, which service(8)
    # refuses.
    my $verbs = join q{|},
      map { quotemeta $_->{verb} } @{ GPForum::Command::Support::Verbs->verbs };
    my $file =
        $LOADED =~ $SHELL_SAFE
      ? $LOADED
      : q{'} . ( $LOADED =~ s/'/'\\''/grmsx ) . q{'};
    $text =~
      s{(?<![\w/.-]) (?<!service[ ]) gpforum [ ] (?= (?:$verbs) (?![\w-]) )}
              {gpforum --env-file $file }gmsx;

    return $text;
}

# Findings as a command prints them in --json
# (GPForum::Service::Operations::Findings/document), each sentence through
# as_read.
sub findings_as_read ( $class, $document ) {
    return [ map { $class->_finding_as_read($_) } @{$document} ];
}

sub _finding_as_read ( $class, $finding ) {
    my %read = %{$finding};
    $read{message} = $class->as_read( $read{message} );
    for my $list (qw(notes fixes)) {
        $read{$list} = [ map { $class->as_read($_) } @{ $read{$list} // [] } ];
    }

    return \%read;
}

# The file this host's service reads its settings from (GPForum::OS): on
# macOS the one under Homebrew's prefix.
sub default_file ($self) {
    return $self->os->environment_file;
}

# The command that restarts what reads the file, or undef on a host GPForum
# ships no units for.
sub restart_command ($self) {
    return _for_host( \%RESTART, $self->os->name );
}

# The command that starts them, or undef where GPForum ships no units.
sub start_command ($self) {
    return _for_host( \%START, $self->os->name );
}

# The file to read: the one named, or the host's when it exists. Undef when
# there is none, which leaves the process environment as it is.
sub chosen_file ($self) {
    return $self->file if defined $self->file;

    my $default = $self->default_file;
    return -e $default ? $default : undef;
}

# Reads the file into the environment, leaving every name the environment
# already has. Returns { file, set, kept }: the file read (undef for none),
# the names it set and the names the environment kept. Throws a
# GPForum::X::Config whose message says what to do when the named file is
# missing, the file cannot be read, or, strictly, a line is not NAME=value.
sub load ($self) {
    my $file = $self->chosen_file;
    return { file => undef, kept => [], set => [] } if !defined $file;

    # A name the file assigns twice takes its last value, as systemd and a
    # shell give the service: the first one would have the front door
    # connect where the service does not. The names the process held before
    # the file was read are the ones it keeps.
    my %held = map { $_ => 1 } keys %{ $self->environment };
    my %value;
    my @order;
    for my $assignment ( @{ $self->read_file($file) } ) {
        my ( $name, $value ) = @{$assignment};
        if ( !exists $value{$name} ) {
            push @order, $name;
        }
        $value{$name} = $value;
    }

    my ( @assigned, @kept );
    for my $name (@order) {
        if ( $held{$name} ) {
            push @kept, $name;
            next;
        }
        $self->environment->{$name} = $value{$name};
        push @assigned, $name;
    }
    $LOADED   = $file;
    @ASSIGNED = @assigned;

    return { file => $file, kept => \@kept, set => \@assigned };
}

# The file's assignments, in order, as [ NAME, value ] pairs.
sub read_file ( $self, $file ) {
    my $handle;
    if ( !-e $file ) {
        _refuse( 'cli.env_file.missing', { file => $file } );
    }
    if ( !open $handle, '<:encoding(UTF-8)', $file ) {
        return [] if !$self->strict;
        _refuse( 'cli.env_file.unreadable',
            { file => $file, reason => "$OS_ERROR" } );
    }
    my @lines = <$handle>;
    close $handle
      or _refuse( 'cli.env_file.unreadable',
        { file => $file, reason => "$OS_ERROR" } );

    my @assignments;
    my $number = 0;
    for my $line (@lines) {
        $number++;
        my $assignment = $self->parse_line($line);
        next if !defined $assignment;
        if ( !ref $assignment ) {
            next if !$self->strict;
            _refuse( 'cli.env_file.malformed',
                { file => $file, line => $number } );
        }
        push @assignments, $assignment;
    }

    return \@assignments;
}

# One line as [ NAME, value ]; undef for a blank line or a comment; the empty
# string for a line that is not an assignment.
sub parse_line ( $class, $line ) {
    $line =~ s/\r?\n\z//msx;
    return undef if $line =~ /\A \s* (?: [#;] | \z )/msx;

    my ( $name, $rest ) =
      $line =~ /\A \s* (?: export \s+ )? ($NAME) \s* = \s* (.*) \z/msx;
    return q{} if !defined $name;

    my $value = _value($rest);
    return defined $value ? [ $name, $value ] : q{};
}

# A value bare, single-quoted (literal) or double-quoted (with \", \\, \$
# and \` escaped); undef for a quote left open or text after the closing
# quote. Bare, a backslash keeps the character after it and is dropped, as
# both systemd and a shell read it: kept, a password written ab\cd reached
# the database as ab\cd from gpforum migrate and as abcd from the service.
sub _value ($text) {
    if ( $text =~ /\A ' ([^']*) ' \s* \z/msx ) {
        return $1;
    }
    if ( $text =~ /\A " ((?: [^"\\] | \\ . )*) " \s* \z/msx ) {
        my $inner = $1;
        $inner =~ s{ \\ (.) }{ exists $ESCAPED{$1} ? $1 : "\\$1" }gemsx;
        return $inner;
    }
    return undef if $text =~ /\A ["']/msx;

    return _bare($text);
}

# A bare value as systemd and a shell read it: a backslash keeps the
# character after it, a space among them, and trailing whitespace that no
# backslash keeps is dropped.
sub _bare ($text) {
    my ( $value, $pending ) = ( q{}, q{} );
    while ( $text =~ / \G (?: \\ (.) | (\s) | (.) ) /gcmsx ) {
        if ( defined $2 ) {
            $pending .= $2;
            next;
        }
        $value .= $pending . ( $1 // $3 );
        $pending = q{};
    }

    return $value;
}

# A constant table's entry for this host, or undef: reading a key a constant
# hash lacks dies.
sub _for_host ( $table, $name ) {
    return exists $table->{$name} ? $table->{$name} : undef;
}

sub _refuse ( $key, $parameters ) {
    require GPForum::Command::Support::Words;
    GPForum::X::Config->throw( message =>
          GPForum::Command::Support::Words->new->text( $key, $parameters ) );
}

1;

__END__

=head1 NAME

GPForum::Command::Support::ServiceEnvironment - The environment file the service
reads, read by the command line too.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $loaded = GPForum::Command::Support::ServiceEnvironment->new->load;
    # { file => '/etc/gpforum/gpforum.env', set => [...], kept => [...] }

    GPForum::Command::Support::ServiceEnvironment->new(
        file => '/srv/gpforum/staging.env' )->load;

=head1 DESCRIPTION

Reads the file a GPForum service takes its settings from --
F</etc/gpforum/gpforum.env>, F</usr/local/etc/gpforum/gpforum.env> on FreeBSD,
F<$(brew --prefix)/etc/gpforum/gpforum.env> on macOS, or the one named with
C<--env-file> -- into the process environment, so a command typed at a shell
sees what the service sees. A name the environment already holds is kept:
the process environment wins over the file, which wins over GPForum's
defaults (ADR 0120).

The format is the one C<deploy/gpforum.env.example> is written in and both
systemd's C<EnvironmentFile=> and a POSIX shell read: C<NAME=value> lines, an
optional leading C<export>, a value bare (where a backslash keeps the
character after it and is dropped), in single quotes (literal) or in
double quotes (with C<\">, C<\\>, C<\$> and C<\`> escaped), and blank lines
and lines starting with C<#> or C<;> ignored. A name the file assigns twice
takes its last value, as both of them do.

=head1 SUBROUTINES/METHODS

=head2 loaded

Class method. The file this process read, or undef when it read none.

=head2 assigned

Class method. The names this process set from the file it read; any other
name its environment holds came from the process environment.

=head2 as_read

Class method. Takes a text and returns it with C<--env-file FILE> in each
C<gpforum VERB> it names, when this process read a file other than the
host's, so a command it offers reads the same settings.

=head2 findings_as_read

Class method. Takes the findings a command prints with C<--json> and
returns them with each message, note and fix through L</as_read>.

=head2 default_file

The file this host's service reads.

=head2 restart_command

The command that restarts the web service and the outbox worker under this
host's supervisor, or undef on an operating system GPForum ships no units
for.

=head2 start_command

The command that starts the web service and the outbox worker under this
host's supervisor, or undef.

=head2 chosen_file

The file L</load> reads: the one given as C<file>, else the host's when it
exists, else undef.

=head2 load

Reads the chosen file into C<environment>, leaving every name it already
holds, and returns C<file>, C<set> and C<kept>. Without a file, returns
C<file> undef and changes nothing.

=head2 read_file

Returns a file's assignments as C<[ NAME, value ]> pairs, in order.

=head2 parse_line

Class method. One line as C<[ NAME, value ]>, undef for a blank line or a
comment, or the empty string for a line that is not an assignment.

=head1 DIAGNOSTICS

Throws L<GPForum::X::Config>, whose message says what to do, in the
operator's language (L<GPForum::Command::Support::Words>), when the named file does
not exist, the file cannot be read (its permissions, say), or a line is not
an assignment while C<strict> is on.

=head1 CONFIGURATION AND ENVIRONMENT

Writes the names the file sets into C<environment>, C<%ENV> by default.
On macOS, L<GPForum::OS> reads C<HOMEBREW_PREFIX> to find the Homebrew
prefix.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<Mojo::File>, L<GPForum::OS>,
L<GPForum::X::Config>, L<GPForum::Command::Support::Words>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A value spread over several lines, which systemd accepts with a trailing
backslash, is not read. The host's supervisor and its restart command are
chosen here by the operating system's name; they belong with the rest of
what differs between operating systems, in L<GPForum::OS>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
