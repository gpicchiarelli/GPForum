# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::CLI::FrontDoor::Carton;

use v5.40;

use Cwd        qw(realpath);
use English    qw(-no_match_vars);
use File::Spec ();
use List::Util qw(any);

our $VERSION = '0.001';

# The dependencies live in local/, installed by Carton for one validated
# Perl. A program started without them on @INC -- bin/gpforum-migrate typed
# on its own, `perl bin/gpforum-outbox-dispatch` -- died at its first
# dependency with "Can't locate Const/Fast.pm in @INC". Loaded first, this
# runs the program again under script/gpforum-carton exec, which puts local/
# on @INC and picks that Perl, as bin/gpforum always did. Only core modules
# are loaded here, since the others may be the ones missing.

# Runs the program again through script/gpforum-carton when this checkout's
# local/ is not on @INC; returns when it is, or when there is no local/ to
# put there, or when Hypnotoad (MOJO_APP_LOADER) loads the program as the
# application, under the Perl and @INC its supervisor chose.
sub import ( $class, @ ) {
    return if defined $ENV{MOJO_APP_LOADER};

    my $root  = $class->root;
    my $local = "$root/local/lib/perl5";
    if ( !-d $local && !$class->has_dependencies ) {
        my @install = $class->setup_install( $PROGRAM_NAME, @ARGV );
        if (@install) {
            system { $install[0] } @install;
            exit( ( $CHILD_ERROR >> 8 ) || 1 ) if $CHILD_ERROR;    ## no critic (ValuesAndExpressions::ProhibitMagicNumbers) -- the exit status sits above the signal's eight bits
        }
    }
    return if !-d $local || $class->on_inc($local);

    # The program as it was typed, so its usage names it as the operator did.
    my $carton = "$root/script/gpforum-carton";
    exec {$carton} $carton, 'exec', $class->program($PROGRAM_NAME), @ARGV
      or die "$PROGRAM_NAME: cannot run $carton: $OS_ERROR\n";
}

# What `gpforum setup` runs first on a checkout without its dependencies,
# as an argument list, or nothing: script/bootstrap-deps, as make
# install-deps-production runs it -- the development tools too for
# --environment development, as make install-deps-postgres -- saying what
# it installs, and with setup's --dry-run installing nothing. The front door
# only, and only its setup verb: any other command, and --help, is left to
# say what it would have said.
sub setup_install ( $class, $program, @arguments ) {
    return () if ( $program =~ s{\A .* /}{}rmsx ) ne 'gpforum';

    my ( $verb, @rest ) = _verb(@arguments);
    return () if ( $verb // q{} ) ne 'setup';
    return () if any { $_ eq '--help' || $_ eq '-h' } @rest;

    return (
        $class->root . '/script/bootstrap-deps',
        '--postgres',
        ( _environment(@rest) eq 'development' ? () : '--production' ),
        '--for-setup',
        ( ( any { $_ eq '--dry-run' } @rest ) ? '--dry-run' : () ),
    );
}

# The verb typed after the front door's own --env-file, and what follows it.
sub _verb (@arguments) {
    while (@arguments) {
        my $argument = shift @arguments;
        if ( $argument eq '--env-file' ) {
            shift @arguments;
            next;
        }
        next      if $argument =~ /\A --env-file=/msx;
        return () if $argument =~ /\A -/msx;

        return ( $argument, @arguments );
    }

    return ();
}

# The environment --environment names, or the empty string.
sub _environment (@arguments) {
    my $environment = q{};
    for my $at ( 0 .. $#arguments ) {
        if ( $arguments[$at] =~ /\A --environment (?: = (.*) )? \z/msx ) {
            $environment = $1 // $arguments[ $at + 1 ] // q{};
        }
    }

    return $environment;
}

# Whether Perl finds the dependencies without local/: a host that installed
# them its own way, as a CI image may.
sub has_dependencies ($class) {
    return (
        any { -f "$_/Mojo/Base.pm" }
        grep { !ref } @INC
    ) ? 1 : 0;
}

# The program as gpforum-carton finds it: a name with no slash -- `perl
# gpforum-migrate`, typed in bin/ -- is a file in this directory, where the
# shell's exec looked for a command on the PATH ("gpforum-migrate: not
# found"). A program found on the PATH has its whole path already.
sub program ( $class, $name ) {
    return $name =~ m{/}msx ? $name : "./$name";
}

# The checkout's root directory: this file is lib/GPForum/CLI/FrontDoor/
# Carton.pm under it.
sub root ($class) {
    my $here = realpath(__FILE__) // File::Spec->rel2abs(__FILE__);

    return $here =~ s{/lib/GPForum/CLI/FrontDoor/Carton[.]pm\z}{}rmsx;
}

# Whether a directory is on @INC, however @INC spells it.
sub on_inc ( $class, $directory ) {
    my $wanted = realpath($directory) // return 0;

    return (
        any { defined realpath($_) && realpath($_) eq $wanted }
        grep { !ref } @INC
    ) ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::CLI::FrontDoor::Carton - Runs a GPForum program under the
dependencies Carton installed.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use FindBin;
    use lib "$FindBin::Bin/../lib";
    use GPForum::CLI::FrontDoor::Carton;    # before any dependency
    use GPForum::Command::Migrate;

=head1 DESCRIPTION

Loaded before anything outside Perl's core, it runs the program again under
C<script/gpforum-carton exec> when the checkout's F<local/lib/perl5> is not
on C<@INC>, so C<bin/gpforum> and every C<bin/gpforum-*> entrypoint work
when typed on their own, under the Perl the checkout was installed for
(ADR 0120). Nothing happens when F<local/> is already on C<@INC>, when the
checkout has no F<local/>, or when Hypnotoad loads C<bin/gpforum> as the
application (C<MOJO_APP_LOADER>). C<gpforum setup> on a checkout without
F<local/> and without the dependencies installs them first, through
C<script/bootstrap-deps>, as C<make install-deps-production> does.

=head1 SUBROUTINES/METHODS

=head2 import

Called by C<use>: runs the program again through C<script/gpforum-carton>
with the same arguments when it must, and returns otherwise.

=head2 setup_install

Class method. Takes the program's name as it was run and its arguments, and
returns what C<gpforum setup> runs first on a checkout without its
dependencies -- C<script/bootstrap-deps> with the options C<make
install-deps-production> gives it, or C<install-deps-postgres>'s for
C<--environment development> -- or an empty list for any other command.

=head2 has_dependencies

Class method. Whether C<@INC> already has the dependencies, without
F<local/>.

=head2 program

Class method. Takes the program's name as it was run and returns it as
C<script/gpforum-carton exec> finds it: a bare name, a file in the current
directory, with C<./> before it.

=head2 root

Class method. The checkout this module belongs to.

=head2 on_inc

Class method. Takes a directory and returns 1 when C<@INC> holds it, under
any spelling that resolves to it.

=head1 DIAGNOSTICS

C<PROGRAM: cannot run CHECKOUT/script/gpforum-carton: REASON> when the
wrapper cannot be started.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<MOJO_APP_LOADER>.

=head1 DEPENDENCIES

Core modules only: L<Cwd>, L<File::Spec>,
L<List::Util>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

It needs a Perl that reads C<use v5.40>: an older one stops before this
module runs. C<bin/gpforum> finds the supported Perl first.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
