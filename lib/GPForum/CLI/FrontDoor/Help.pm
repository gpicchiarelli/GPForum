# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::CLI::FrontDoor::Help;

use Const::Fast;
use List::Util qw(max);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Loader qw(load_class);

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Verbs;
use GPForum::Command::Support::Words;

our $VERSION = '0.001';

# Mojolicious's own commands that still work through the front door, for
# `gpforum help --all`: an operator who knew `gpforum daemon` or `gpforum
# routes` keeps them, and `gpforum minion worker` runs Minion's workers where
# GPFORUM_MINION_ENABLED registers them. generate, cpanify and inflate are an
# author's, not an operator's, and are not registered.
const my @FRAMEWORK =>
  qw(cgi daemon eval get minion prefork psgi routes version);
const my %FRAMEWORK_NAMESPACE => ( minion => 'Minion::Command' );

const my $INDENT => q{  };
const my $GUTTER => 3;

has words => sub { return GPForum::Command::Support::Words->new; };
has environment =>
  sub { return GPForum::Command::Support::ServiceEnvironment->new; };

sub framework ($class) {
    return [@FRAMEWORK];
}

# The class that runs one of the framework's commands.
sub framework_class ( $class, $name ) {
    my $namespace =
      exists $FRAMEWORK_NAMESPACE{$name}
      ? $FRAMEWORK_NAMESPACE{$name}
      : 'Mojolicious::Command';

    return "${namespace}::$name";
}

# The front door's help: how to call it, the verbs by what an operator is
# doing, where the settings come from, and where to read more. With all, the
# benchmarks, seeds, drills and evidence, and Mojolicious's own commands,
# too.
sub render ( $self, $all = 0 ) {
    my @groups = grep { $all || $_ ne 'more' }
      @{ GPForum::Command::Support::Verbs->groups };
    my @sections;
    for my $group (@groups) {
        my @rows = map { [ $_->{verb}, $self->describe($_) ] }
          grep { $_->{group} eq $group && $self->installed($_) }
          @{ GPForum::Command::Support::Verbs->verbs };
        push @sections, [ $self->_said("cli.help.group.$group"), \@rows ];
    }
    if ($all) {
        push @sections,
          [
            $self->_said('cli.help.group.framework'),
            [
                map  { [ $_, _framework_description($_) ] }
                grep { $self->_framework_installed($_) } @FRAMEWORK
            ]
          ];
    }

    my $width =
      $GUTTER + max map { length $_->[0] } map { @{ $_->[1] } } @sections;
    my @lines = ( $self->_said('cli.help.usage'), q{} );
    for my $section (@sections) {
        my ( $title, $rows ) = @{$section};
        push @lines, $title,
          map { sprintf q{%s%-*s%s}, $INDENT, $width, @{$_} } @{$rows};
        push @lines, q{};
    }
    push @lines, $self->settings_line,
      $self->_said( $all ? 'cli.help.footer_all' : 'cli.help.footer' );

    return join( "\n", @lines ) . "\n";
}

# Where this host's settings come from, as the help's closing lines say. A
# file named with --env-file that is not there is said so, as every command
# would refuse it: the help said settings were read from it.
sub settings_line ($self) {
    my $file = $self->environment->chosen_file;
    if ( defined $file && !-e $file ) {
        return $self->_said( 'cli.env_file.missing', { file => $file } );
    }
    return $self->_said( 'cli.help.settings_file', { file => $file } )
      if defined $file;

    return $self->_said( 'cli.help.settings_shell',
        { file => $self->environment->default_file } );
}

# A verb's one line: the catalog's, in the operator's language, else the
# command's own description.
sub describe ( $self, $verb ) {
    my $key      = 'cli.verb.' . ( $verb->{verb} =~ tr/-/_/r );
    my $template = $self->words->template($key);
    return $self->_said($key) if defined $template;

    my $class = 'GPForum::CLI::' . $verb->{command};
    return $self->installed($verb) ? $class->new->description : q{};
}

# Whether a verb's command is there to run: a command another change has
# yet to add is left out of the help rather than offered.
sub installed ( $self, $verb ) {
    my $class = 'GPForum::CLI::' . $verb->{command};
    my $error = load_class($class);
    return 0 if $error;

    return $class->isa('Mojolicious::Command') ? 1 : 0;
}

sub _framework_installed ( $self, $name ) {
    return load_class( __PACKAGE__->framework_class($name) ) ? 0 : 1;
}

sub _framework_description ($name) {
    my $class = __PACKAGE__->framework_class($name);
    return q{} if load_class($class);

    return $class->new->description;
}

sub _said ( $self, $key, $parameters = {} ) {
    return $self->words->text( $key, $parameters );
}

1;

__END__

=head1 NAME

GPForum::CLI::FrontDoor::Help - What C<gpforum> and C<gpforum help> print.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    print GPForum::CLI::FrontDoor::Help->new->render;        # gpforum help
    print GPForum::CLI::FrontDoor::Help->new->render(1);     # gpforum help --all

=head1 DESCRIPTION

The front door's own help, in the operator's language: the verbs grouped as
an operator works -- Set up, Run, Check, Maintain -- each with one line, then
where this host's settings come from. C<--all> adds the benchmarks, seeds,
drills and evidence commands, and Mojolicious's own. It replaced
Mojolicious's generic banner, which offered C<mojo generate lite-app> and a
C<--mode> nothing read.

=head1 SUBROUTINES/METHODS

=head2 framework

Class method. The names of Mojolicious's commands the front door still runs.

=head2 framework_class

Class method. The class that runs one of L</framework>'s names.

=head2 render

The help, ending in a newline; given a true value, with every command.

=head2 settings_line

The line that says which environment file this host's settings are read
from, or that there is none and the shell's environment is all.

=head2 describe

A verb's one line, from the CLI catalog when it has one.

=head2 installed

Whether a verb's command loads.

=head1 DIAGNOSTICS

A command module that does not compile is left out, as one that is not
there.

=head1 CONFIGURATION AND ENVIRONMENT

The language follows C<LC_ALL>, C<LC_MESSAGES> or C<LANG>
(L<GPForum::Command::Support::Words>).

=head1 DEPENDENCIES

L<Mojo::Loader>, L<GPForum::Command::Support::Verbs>,
L<GPForum::Command::Support::Words>,
L<GPForum::Command::Support::ServiceEnvironment>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
